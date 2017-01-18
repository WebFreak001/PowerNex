module kmain;

version (PowerNex) {
	// Good job, you are now able to compile PowerNex!
} else {
	static assert(0, "Please use the customized toolchain located here: http://wild.tk/PowerNex-Env.tar.xz");
}

import memory.allocator;
import io.com;
import io.log;
import cpu.gdt;
import cpu.idt;
import cpu.pit;
import data.color;
import data.multiboot;
import hw.ps2.keyboard;
import memory.paging;
import memory.frameallocator;
import data.linker;
import data.address;
import memory.heap;
import task.scheduler;
import acpi.rsdp;
import hw.pci.pci;
import hw.cmos.cmos;
import system.syscallhandler;
import data.textbuffer : scr = getBootTTY;
import data.elf;
import io.consolemanager;
import memory.ref_;
import fs;

private immutable uint _major = __VERSION__ / 1000;
private immutable uint _minor = __VERSION__ % 1000;

__gshared Ref!FileSystem rootFS;

extern (C) int kmain(uint magic, ulong info) {
	preInit();
	welcome();
	init(magic, info);
	asm {
		sti;
	}

	string initFile = "/bin/init";
	ELF init = new ELF(rootFS.root.findNode(initFile));
	if (init.valid) {
		scr.writeln(initFile, " is valid! Loading...");
		scr.writeln();
		scr.foreground = Color(255, 255, 0);
		init.mapAndRun([initFile]);
	} else {
		scr.writeln("Invalid ELF64 file");
		log.fatal("Invalid ELF64 file!");
	}

	scr.foreground = Color(255, 0, 255);
	scr.background = Color(255, 255, 0);
	scr.writeln("kmain functions has exited!");
	log.fatal("kmain functions has exited!");
	return 0;
}

void bootTTYToTextmode(size_t start, size_t end) {
	import io.textmode;

	if (start == -1 && end == -1)
		getScreen.clear();
	else
		getScreen.write(scr.buffer[start .. end]);
}

void preInit() {
	import io.textmode;

	initEarlyStaticAllocator();
	COM.init();
	scr;
	scr.onChangedCallback = &bootTTYToTextmode;
	getScreen.clear();

	scr.writeln("ACPI initializing...");
	rsdp.init();
	scr.writeln("CMOS initializing...");
	getCMOS();
	scr.writeln("Log initializing...");
	log.init();
	scr.writeln("GDT initializing...");
	GDT.init();
	scr.writeln("IDT initializing...");
	IDT.init();
	scr.writeln("Syscall Handler initializing...");
	SyscallHandler.init();

	scr.writeln("PIT initializing...");
	PIT.init();
	scr.writeln("Keyboard initializing...");
	PS2Keyboard.init();
}

void welcome() {
	scr.writeln("Welcome to PowerNex!");
	scr.writeln("\tThe number one D kernel!");
	scr.writeln("Compiled using '", __VENDOR__, "', D version ", _major, ".", _minor, "\n");
	log.info("Welcome to PowerNex's serial console!");
	log.info("Compiled using '", __VENDOR__, "', D version ", _major, ".", _minor, "\n");
}

void init(uint magic, ulong info) {
	scr.writeln("Multiboot parsing...");
	log.info("Multiboot parsing...");
	Multiboot.parseHeader(magic, info);

	{
		VirtAddress[2] symmap = Multiboot.getModule("symmap");
		if (symmap[0]) {
			log.setSymbolMap(symmap[0]);
			log.info("Successfully loaded symbols!");
		} else
			log.fatal("No module called symmap!");
	}

	scr.writeln("FrameAllocator initializing...");
	log.info("FrameAllocator initializing...");
	FrameAllocator.init();

	scr.writeln("Paging initializing...");
	log.info("Paging initializing...");
	getKernelPaging.removeUserspace(false); // Removes all mapping that are not needed for the kernel
	getKernelPaging.install();
	scr.writeln("Heap initializing...");
	log.info("Heap initializing...");
	getKernelHeap;

	{
		import memory.allocator.heapallocator : HeapAllocator;

		kernelAllocator = new HeapAllocator(getKernelHeap);
	}

	scr.writeln("PCI initializing...");
	log.info("PCI initializing...");
	getPCI;
	scr.writeln("Initrd initializing...");
	log.info("Initrd initializing...");
	loadInitrd();
	scr.writeln("Starting ConsoleManager...");
	log.info("Starting ConsoleManager...");
	getConsoleManager.init();
	scr.writeln("Scheduler initializing...");
	log.info("Scheduler initializing...");
	getScheduler.init();
}

void loadInitrd() {
	import fs.tarfs : TarFS;
	import fs.iofs : IOFS;

	VirtAddress[2] tarfsLoc = Multiboot.getModule("tarfs");
	if (!tarfsLoc[0]) {
		log.fatal("No module called tarfs!");
		return;
	}

	ubyte[] tarfsData = VirtAddress().ptr!ubyte[tarfsLoc[0].num .. tarfsLoc[1].num];

	rootFS = cast(Ref!FileSystem)kernelAllocator.makeRef!TarFS(tarfsData);

	Ref!FileSystem iofs = cast(Ref!FileSystem)kernelAllocator.makeRef!IOFS();

	rootFS.root.mount("io", iofs);

	char[8] levelStr = "||||||||";
	void printData(Ref!VNode node, int level = 0) {
		if (node.type == NodeType.directory) {
			Ref!DirectoryEntryRange range;

			IOStatus ret = node.dirEntries(range);
			if (ret) {
				log.error("dirEntries: ", -ret, ", ", node.name, "(", node.id, ")", " node:", typeid(node.data).name, " fs:",
						typeid(node.fs).name);
				return;
			}
			int nextLevel = level + 1;
			if (nextLevel > levelStr.length)
				nextLevel = levelStr.length;
			foreach (idx, ref DirectoryEntry e; range.data) {
				if (e.name.length && e.name[0] == '.')
					continue;
				Ref!VNode n = e.fileSystem.getNode(e.id);
				if (!n)
					continue;
				log.info(levelStr[0 .. level], "»", e.name, " type: ", n.type, " id: ", n.id);
				printData(n, nextLevel);
			}
		}
	}

	log.info("directoryEntries for rootFS!\n---------------------");
	printData(rootFS.root);
}
