import PowerNex.Syscall;
import PowerNex.Data.Address;
import PowerNex.Data.String;
import PowerNex.Data.BMPImage;
import PowerNex.Data.Color;

// Port of https://github.com/ArkArk/BurningDmanAndGopher.git

void Print(string str) {
	Syscall.Write(0UL, cast(ubyte[])str, 0UL);
}

void Println(string str) {
	Print(str);
	Print("\n");
}

__gshared size_t fb;
__gshared size_t fbWidth;

struct Tile {
	size_t fd;
	BMPImage Image;

	alias Image this;

	this(string path) {
		fd = Syscall.Open(path);
		if (!fd) {
			Print("Failed to load image ");
			Println(path);
			return;
		}
		Image = new BMPImage(fd);
	}

	~this() {
		Syscall.Close(fd);
	}

	void Draw(size_t x, size_t y) {
		for (size_t row = 0; row < Image.Height; row++) {
			auto dataRow = Image.Data[row * Image.Width .. (row + 1) * Image.Width];
			size_t yPos = row + y;
			Syscall.Write(fb, cast(ubyte[])dataRow, (yPos * fbWidth + x) * Color.sizeof);
		}
	}
}

void outline(size_t width, size_t height)(size_t x, size_t y, Color color = Color(255, 0, 0)) {
	static if (width == 0)
		return;
	Color[width] fullLine;
	Color[1] outline = [color];

	for (size_t i = 0; i < width; i++)
		fullLine[i] = color;

	Syscall.Write(fb, cast(ubyte[])fullLine, 0);
	Syscall.Write(fb, cast(ubyte[])fullLine, (y * fbWidth + x) * Color.sizeof);
	static if (height > 1)
		Syscall.Write(fb, cast(ubyte[])fullLine, ((y + height - 1) * fbWidth + x) * Color.sizeof);
	static if (height > 2)
		for (size_t i = 1; i < height - 1; i++) {
			Syscall.Write(fb, cast(ubyte[])outline, ((y + i) * fbWidth + x) * Color.sizeof);
			Syscall.Write(fb, cast(ubyte[])outline, ((y + i) * fbWidth + x + width - 1) * Color.sizeof);
		}
}

void outlineClear(size_t width, size_t height)(size_t x, size_t y, Color color = Color(255, 0, 0)) {
	static if (width == 0)
		return;
	Color[width] fullLine;
	Color[width] outline;

	for (size_t i = 0; i < width; i++) {
		fullLine[i] = color;
		outline[i] = Color(0, 0, 0);
	}
	outline[0] = outline[$ - 1] = color;

	for (size_t i = 0; i < height; i++)
		Syscall.Write(fb, cast(ubyte[])(i == 0 || i == height - 1 ? fullLine : outline), ((y + i) * fbWidth + x) * Color.sizeof);
}

enum TileType : ubyte {
	Empty,
	DMan,
	Gopher,
	Bomb,
	BombIgnited,
	BombExtinguished,
	Fire
}

bool isBomb(TileType type) {
	return type == TileType.Bomb || type == TileType.BombIgnited || type == TileType.BombExtinguished;
}

void ignite(ref TileType tile) {
	if (tile == TileType.Bomb)
		tile = TileType.BombIgnited;
	else
		tile = TileType.Fire;
}

__gshared bool running = true;
__gshared uint lastKey = 0;

enum NumTilesX = 10;
enum NumTilesY = 10;

ulong keyboardHandler(void*)
{
	ubyte[4] buf;
	while (running) {
		Syscall.Read(0, buf, 0);
		lastKey = buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
	}
	return 0;
}

struct Random
{
	ulong x = 56447, y = 48914, z = 84792;

	ulong next()
	{
		x ^= x << 16;
		x ^= x >> 5;
		x ^= x << 1;

		ulong t = x;
		x = y;
		y = z;
		z = t ^ x ^ y;

		return z;
	}
}

Random rng;

void seed(ulong l) {
	rng.x = l + 1;
	rng.y = l + 2;
	rng.z = l + 3;
}

int random(int max) {
	return cast(uint) (rng.next % max);
}

T max(T)(T a, T b) {
	return a > b ? a : b;
}

int main(string[] args) {
	scope (exit)
		running = false;

	Syscall.Clone(&keyboardHandler, VirtAddress.init, null, "");

	ulong rngSeed = 1;

	Println("Burning D-man and Gopher");
	Println("port of https://arkark.github.io/BurningDmanAndGopher/");
	Print("\n");
	Println("WASD to move cursor around");
	Println("I click to ignite a bomb");
	Println("O click to extinguish a bomb");
	Print("\n");
	Println("Press any key to start");
	while (lastKey == 0)
		rngSeed++;
	seed(rngSeed);

	fb = Syscall.Open("/IO/Framebuffer/Framebuffer1");
	if (!fb)
		return 1;
	scope (exit)
		Syscall.Close(fb);

	Tile bomb = Tile("/Data/Game/bomb.bmp");
	Tile bombIg = Tile("/Data/Game/bombIg.bmp");
	Tile bombEx = Tile("/Data/Game/bombEx.bmp");
	Tile dman = Tile("/Data/Game/dman.bmp");
	Tile fire = Tile("/Data/Game/fire.bmp");
	Tile firePreview = Tile("/Data/Game/firePreview.bmp");
	Tile gopher = Tile("/Data/Game/gopher.bmp");
	Tile tile = Tile("/Data/Game/tile.bmp");

	if (!bomb.fd || !bombIg.fd || !bombEx.fd || !dman.fd || !fire.fd || !firePreview.fd || !gopher.fd || !tile.fd)
		return 2;

	size_t[2] displaySize;
	Syscall.Read(fb, cast(ubyte[])displaySize, 0);
	fbWidth = displaySize[0];

	auto tileW = tile.Width;
	auto tileH = tile.Height;

	auto boardW = tileW * NumTilesX;
	auto boardH = tileH * NumTilesY;

	TileType[NumTilesX * NumTilesY] tiles;

	const size_t xoff = displaySize[0] / 2 - boardW / 2;
	const size_t yoff = displaySize[1] / 2 - boardH / 2;

	void drawTile(ubyte x, ubyte y) {
		switch (tiles[x + y * NumTilesX]) {
		case TileType.Empty:
			tile.Draw(x * tile.Width + xoff, y * tile.Height + yoff);
			break;
		case TileType.DMan:
			dman.Draw(x * dman.Width + xoff, y * dman.Height + yoff);
			break;
		case TileType.Gopher:
			gopher.Draw(x * gopher.Width + xoff, y * gopher.Height + yoff);
			break;
		case TileType.Bomb:
			bomb.Draw(x * bomb.Width + xoff, y * bomb.Height + yoff);
			break;
		case TileType.BombIgnited:
			bombIg.Draw(x * bombIg.Width + xoff, y * bombIg.Height + yoff);
			break;
		case TileType.BombExtinguished:
			bombEx.Draw(x * bombEx.Width + xoff, y * bombEx.Height + yoff);
			break;
		case TileType.Fire:
			fire.Draw(x * fire.Width + xoff, y * fire.Height + yoff);
			break;
		default:
			break;
		}
	}

	for (ubyte y = 0; y < NumTilesY; y++) {
		for (ubyte x = 0; x < NumTilesX; x++) {
			drawTile(x, y);
		}
	}

	bool regen = true;
	bool animate = false;
	int stageIndex = -1;
	int restTime, totalTime, animationTime;
	ubyte prevCursorX, prevCursorY;
	ubyte cursorX = 5, cursorY = 5;
	char[8] buf;

	immutable int[12] dx = [-3, -2, -1, 1, 2, 3, 0, 0, 0, 0, 0, 0];
	immutable int[12] dy = [0, 0, 0, 0, 0, 0, -1, -2, -3, 1, 2, 3];

	void genGopher(int numGopher) {
		for (int n = 0; n < numGopher; n++) {
			while (true) {
				int x = random(NumTilesX);
				int y = random(NumTilesY);
				int k = random(dx.length);
				int xMod = x + dx[k];
				int yMod = y + dy[k];
				if (xMod < 0 || xMod >= NumTilesX || yMod < 0 || yMod >= NumTilesY) continue;
				if (tiles[x + y * NumTilesX] != TileType.Empty) continue;
				if (tiles[xMod + yMod * NumTilesX] != TileType.Empty) continue;
				tiles[x + y * NumTilesX] = TileType.Gopher;
				tiles[xMod + yMod * NumTilesX] = TileType.Bomb;
				break;
			}
		}
	}


	void genDMen(int numDMan, bool placeBomb) {
		for(int n = 0; n < numDMan; n++) {
			while(true) {
				int x = random(NumTilesX);
				int y = random(NumTilesY);
				if (tiles[x + y * NumTilesX] != TileType.Empty) continue;
				bool preventSpawn = false;
				for (int k = 0; k < dx.length; k++) {
					int xMod = x + dx[k];
					int yMod = y + dy[k];
					if (xMod >= 0 && xMod < NumTilesX && yMod >= 0 && yMod < NumTilesY) {
						if (tiles[xMod + yMod * NumTilesX] == TileType.Bomb) {
							preventSpawn = true;
							break;
						}
					}
				}
				if (preventSpawn) continue;
				if (placeBomb) {
					int k = random(dx.length);
					int xMod = x + dx[k];
					int yMod = y + dy[k];
					if (xMod < 0 || xMod >= NumTilesX || yMod < 0 || yMod >= NumTilesY) continue;
					tiles[x + y * NumTilesX] = TileType.DMan;
					tiles[xMod + yMod * NumTilesX] = TileType.Bomb;
				}
				else
					tiles[x + y * NumTilesX] = TileType.DMan;
				break;
			}
		}
	}

	void genBombs(int numExtraBombs) {
		for (int n = 0; n < numExtraBombs; n++) {
			while (true) {
				int x = random(NumTilesX);
				int y = random(NumTilesY);
				if (tiles[x + y * NumTilesX] != TileType.Empty) continue;
				tiles[x + y * NumTilesX] = TileType.Bomb;
				break;
			}
		}
	}

	void easyStage(int numGopher, int numDMan, int numExtraBombs) {
		genGopher(numGopher);
		genDMen(numDMan, false);
		genBombs(numExtraBombs);
	}

	void normalStage(int numGopher, int numDMan, int numExtraBombs) {
		genGopher(numGopher);
		genDMen(numDMan, true);
		genBombs(numExtraBombs);
	}

	void drawBombCross(ubyte x, ubyte y, bool add, bool generate = false) {
		for (ubyte i = 1; i <= 3; i++) {
			if (generate) {
				if (x + i < NumTilesX) {
					tiles[x + i + y * NumTilesX].ignite;
					drawTile(cast(ubyte) (x + i), y);
				}
				if (i <= x) {
					tiles[x - i + y * NumTilesX].ignite;
					drawTile(cast(ubyte) (x - i), y);
				}
				if (y + i < NumTilesY) {
					tiles[x + (y + i) * NumTilesX].ignite;
					drawTile(x, cast(ubyte) (y + i));
				}
				if (i <= y) {
					tiles[x + (y - i) * NumTilesX].ignite;
					drawTile(x, cast(ubyte) (y - i));
				}
			}
			else if (add) {
				if (x + i < NumTilesX) {
					auto px = (x + i) * firePreview.Width + xoff;
					auto py = y * firePreview.Height + yoff;
					if (tiles[x + i + y * NumTilesX] == TileType.Bomb)
						bombIg.Draw(px, py);
					else
						firePreview.Draw(px, py);
				}
				if (i <= x) {
					auto px = (x - i) * firePreview.Width + xoff;
					auto py = y * firePreview.Height + yoff;
					if (tiles[x - i + y * NumTilesX] == TileType.Bomb)
						bombIg.Draw(px, py);
					else
						firePreview.Draw(px, py);
				}
				if (y + i < NumTilesY) {
					auto px = x * firePreview.Width + xoff;
					auto py = (y + i) * firePreview.Height + yoff;
					if (tiles[x + (y + i) * NumTilesX] == TileType.Bomb)
						bombIg.Draw(px, py);
					else
						firePreview.Draw(px, py);
				}
				if (i <= y) {
					auto px = x * firePreview.Width + xoff;
					auto py = (y - i) * firePreview.Height + yoff;
					if (tiles[x + (y - i) * NumTilesX] == TileType.Bomb)
						bombIg.Draw(px, py);
					else
						firePreview.Draw(px, py);
				}
			}
			else {
				if (x + i < NumTilesX)
					drawTile(cast(ubyte) (x + i), y);
				if (i <= x)
					drawTile(cast(ubyte) (x - i), y);
				if (y + i < NumTilesY)
					drawTile(x, cast(ubyte) (y + i));
				if (i <= y)
					drawTile(x, cast(ubyte) (y - i));
			}
		}
	}

	void redrawCursor() {
		outline!(32, 30)(cursorX * 32 + xoff, cursorY * 32 + yoff + 1);
		outline!(30, 32)(cursorX * 32 + xoff + 1, cursorY * 32 + yoff);
	}

	while (true) {
		if (animate) {
			if (animationTime > 500) {
				animationTime = 0;
				bool exploded = false;
				auto orig = tiles;
				int numDMan = 0;
				int numAlive = 0;
				int numGopher = 0;
				for (ubyte x = 0; x < NumTilesX; x++) {
					for (ubyte y = 0; y < NumTilesY; y++) {
						if (orig[x + y * NumTilesX] == TileType.DMan)
							numDMan++;
						if (orig[x + y * NumTilesX] == TileType.Gopher)
							numGopher++;
						if (orig[x + y * NumTilesX] == TileType.BombIgnited) {
							exploded = true;
							drawBombCross(x, y, false, true);
							tiles[x + y * NumTilesX] = TileType.Fire;
							drawTile(x, y);
						}
					}
				}
				for (size_t i = 0; i < NumTilesX * NumTilesY; i++)
					if (tiles[i] == TileType.DMan)
						numAlive++;
				if (numDMan != numAlive) {
					Println("Game Over, you exploded a D-Man");
					return 0;
				}
				if (!exploded) {
					if (numGopher > 0) {
						Println("Game Over, a Gopher has survived");
						return 0;
					}
					animate = false;
					regen = true;
				}
			}
			animationTime++;
		}
		else {
			if (regen) {
				for (size_t i = 0; i < NumTilesX * NumTilesY; i++) {
					tiles[i] = TileType.Empty;
					drawTile(cast(ubyte) (i % NumTilesX), cast(ubyte) (i / NumTilesX));
				}

				if (stageIndex<1)
					easyStage(1, 0, 1);
				else if (stageIndex<2)
					easyStage(1, 1, 1);
				else if (stageIndex<4)
					normalStage(2, 1, 1);
				else if (stageIndex<10)
					normalStage(random(2 + 1) + 2, random(2 + 1) + 1, random(1 + 1) + 1);
				else if (stageIndex<15)
					normalStage(random(3 + 1) + 2, random(2 + 1) + 1, random(2 + 1) + 3);
				else
					normalStage(random(3 + 1) + 2, random(3 + 1) + 1, random(4 + 1) + 4);

				for (size_t i = 0; i < NumTilesX * NumTilesY; i++)
					if (tiles[i] != TileType.Empty)
						drawTile(cast(ubyte) (i % NumTilesX), cast(ubyte) (i / NumTilesX));

				restTime = totalTime = max(2500, 4000 - stageIndex * 50) * 13 / 10; // 30% more time because only keyboard
				regen = false;
				stageIndex++;

				outlineClear!(320, 20)(xoff, yoff - 24);
				cursorX = cursorY = 5;
				animationTime = 0;
			}
			if (lastKey != 0) {
				char key = cast(char) (lastKey & 0xFF);
				byte xmov = 0;
				byte ymov = 0;
				auto curTile = tiles[cursorX + cursorY * NumTilesX];
				switch (key) {
				case 'w':
					ymov = -1;
					break;
				case 'a':
					xmov = -1;
					break;
				case 's':
					ymov = 1;
					break;
				case 'd':
					xmov = 1;
					break;
				case 'i':
					if (curTile == TileType.Bomb || curTile == TileType.BombExtinguished) {
						tiles[cursorX + cursorY * NumTilesX] = TileType.BombIgnited;
						drawTile(cursorX, cursorY);
					} else if (curTile == TileType.BombIgnited) {
						tiles[cursorX + cursorY * NumTilesX] = TileType.Bomb;
						drawTile(cursorX, cursorY);
					}
					break;
				case 'o':
					if (curTile == TileType.Bomb || curTile == TileType.BombIgnited) {
						tiles[cursorX + cursorY * NumTilesX] = TileType.BombExtinguished;
						drawTile(cursorX, cursorY);
					} else if (curTile == TileType.BombExtinguished) {
						tiles[cursorX + cursorY * NumTilesX] = TileType.Bomb;
						drawTile(cursorX, cursorY);
					}
					break;
				default:
					break;
				}
				redrawCursor();
				if (xmov == -1 && cursorX > 0)
					cursorX--;
				else if (xmov == -1 && cursorX == 0)
					cursorX = NumTilesX - 1;
				if (xmov == 1 && cursorX < NumTilesX - 1)
					cursorX++;
				else if (xmov == 1 && cursorX == NumTilesX - 1)
					cursorX = 0;
				if (ymov == -1 && cursorY > 0)
					cursorY--;
				else if (ymov == -1 && cursorY == 0)
					cursorY = NumTilesY - 1;
				if (ymov == 1 && cursorY < NumTilesY - 1)
					cursorY++;
				else if (ymov == 1 && cursorY == NumTilesY - 1)
					cursorY = 0;
				lastKey = 0;
			}
			if (prevCursorX != cursorX || prevCursorY != cursorY) {
				drawTile(prevCursorX, prevCursorY);

				if (tiles[prevCursorX + prevCursorY * NumTilesX].isBomb)
					drawBombCross(prevCursorX, prevCursorY, false);
				if (tiles[cursorX + cursorY * NumTilesX].isBomb)
					drawBombCross(cursorX, cursorY, true);

				redrawCursor();

				prevCursorX = cursorX;
				prevCursorY = cursorY;
			}
			outline!(1, 18)(xoff + 320 - restTime * 320 / totalTime, yoff - 23);
			restTime--;
			if (restTime <= 0) {
				animate = true;
				animationTime = 480;
			}
		}
		Syscall.Sleep(1);
	}

	return 0;
}