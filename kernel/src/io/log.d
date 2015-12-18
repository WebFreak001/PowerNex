module io.log;

import io.com;
import data.string;
import data.util;

__gshared Log log;

enum LogLevel {
	VERBOSE = '&',
	DEBUG   = '+',
	INFO    = '*',
	WARNING = '#',
	ERROR   = '-',
	FATAL   = '!'
}

struct Log {
	int indent;

	void Init() {
		COM1.Init();
		indent = 0;
	}

	void opCall(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(LogLevel level, Arg args) {
		for (int i = 0; i < indent; i++)
			COM1.Write(' ');

		COM1.Write('[', cast(char)level, "] ", file /*, ": ", func*/, '@');

		ubyte[int.sizeof * 8] buf;
		auto start = itoa(line, buf.ptr, buf.length, 10);
		for (size_t i = start; i < buf.length; i++)
			COM1.Write(buf[i]);

		COM1.Write("> ");
		foreach (arg; args) {
			alias T = Unqual!(typeof(arg));
			static if (is(T : const char[]))
				COM1.Write(arg);
			/*else static if (is(T == enum))
				WriteEnum(arg);*/
			else static if (is(T : V *, V)) {
				COM1.Write("0x");
				start = itoa(cast(ulong)arg, buf.ptr, buf.length, 16);
				for (size_t i = start; i < buf.length; i++)
					COM1.Write(buf[i]);
			} else static if (is(T : char))
				COM1.Write(arg);
			else static if (isNumber!T) {
				start = itoa(arg, buf.ptr, buf.length, 10);
				for (size_t i = start; i < buf.length; i++)
					COM1.Write(buf[i]);
			} else
				COM1.Write("UNKNOWN TYPE '", T.stringof, "'");
		}

		COM1.Write("\r\n");
	}

	void Verbose(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(Arg args) {
		this.opCall!(file, func, line)(LogLevel.VERBOSE, args);
	}

	void Debug(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(Arg args) {
		this.opCall!(file, func, line)(LogLevel.DEBUG, args);
	}

	void Info(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(Arg args) {
		this.opCall!(file, func, line)(LogLevel.INFO, args);
	}

	void Warning(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(Arg args) {
		this.opCall!(file, func, line)(LogLevel.WARNING, args);
	}

	void Error(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(Arg args) {
		this.opCall!(file, func, line)(LogLevel.ERROR, args);
	}

	void Fatal(string file = __FILE__, string func = __PRETTY_FUNCTION__, int line = __LINE__, Arg...)(Arg args) {
		this.opCall!(file, func, line)(LogLevel.FATAL, args);
		asm {
		forever:
			hlt;
			jmp forever;
		}
	}

}
