module pacchettino.uuid;

/// Predefined namespaces for UUID v3 and v5
enum UUIDNamespace : ubyte[16] {
	DNS = [
		0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
		0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8
	],

	URL = [
		0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
		0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8
	],

	OID = [
		0x6b, 0xa7, 0xb8, 0x12, 0x9d, 0xad, 0x11, 0xd1,
		0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8
	],

	X500 = [
		0x6b, 0xa7, 0xb8, 0x14, 0x9d, 0xad, 0x11, 0xd1,
		0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8
	]
}

/// Generate a UUID v4 (random bytes) as string
string UUIDv4(T = string)() if(is(T==string)) { return formatUUID(UUIDv4!ubyte); }

/// Generate a UUID v4 (random bytes) as ubyte[16]
ubyte[16] UUIDv4(T)() if (is(T == ubyte))
{
	ubyte[16] value;
	randomBytes(value);

	value[6] = (value[6] & 0x0f) | 0x40;
	value[8] = (value[8] & 0x3f) | 0x80;

	return value;
}

/// Generate a UUIDv7 (timestamp based + counter + random bytes) as string
string UUIDv7(T = string)() if(is(T==string)) { return formatUUID(UUIDv7!ubyte); }

/// Generate a UUIDv7 (timestamp based + counter + random bytes) as ubyte[16]
ubyte[16] UUIDv7(T)() if (is(T == ubyte))
{
	import core.atomic 	: atomicLoad, cas;
	import std.datetime 	: DateTime, SysTime, Clock, UTC;

	shared static immutable unixEpoch = SysTime(DateTime(1970, 1, 1, 0, 0, 0), UTC());

	ubyte[16] value;

	randomBytes(value);

	// Current timestamp in ms
	auto now = Clock.currTime(UTC());
	auto timestamp = (now - unixEpoch).total!"msecs";

	// Packed state: [48-bit timestamp ms | 12-bit counter]
	shared static ulong state = 0;

	ulong oldState, newState;
	ulong localCounter, localTimestamp;

	do {
		oldState = atomicLoad(state);
		ulong storedTs      = oldState >> 12;
		ulong storedCounter = oldState & 0xFFF;

		if (cast(ulong)timestamp > storedTs)
		{
			// New millisecond: counter to zero
			newState       = cast(ulong)timestamp << 12;
			localTimestamp = cast(ulong)timestamp;
			localCounter   = 0;
		}
		else
		{
			// Same ms (or clock backward): increment, use stored timestamp
			localTimestamp = storedTs;
			localCounter   = (storedCounter + 1) & 0xFFF;
			newState       = (storedTs << 12) | localCounter;
		}

	} while (!cas(&state, oldState, newState));

	value[0] = cast(ubyte)((localTimestamp >> 40) & 0xff);
	value[1] = cast(ubyte)((localTimestamp >> 32) & 0xff);
	value[2] = cast(ubyte)((localTimestamp >> 24) & 0xff);
	value[3] = cast(ubyte)((localTimestamp >> 16) & 0xff);
	value[4] = cast(ubyte)((localTimestamp >> 8) & 0xff);
	value[5] = cast(ubyte)(localTimestamp & 0xff);

	// Counter
	value[6] = (value[6] & 0xF0) | cast(ubyte)((localCounter >> 8) & 0x0F);
	value[7] = cast(ubyte)(localCounter & 0xFF);

	// Version & Variant
	value[6] = (value[6] & 0x0f) | 0x70;
	value[8] = (value[8] & 0x3f) | 0x80;

	return value;
}

/// Generate a UUID v3 (namespace + name based with MD5) as string
string UUIDv3(T = string)(string name, ubyte[16] namespace = ubyte[16].init) if(is(T==string)) {
	import std.string : representation;
	return UUIDv3!T(cast(ubyte[])name.representation, namespace);
}

/// Generate a UUID v3 (namespace + name based with MD5) as string
string UUIDv3(T = string)(ubyte[] name, ubyte[16] namespace = ubyte[16].init) if(is(T==string)) {
	return formatUUID(UUIDv3!ubyte(name, namespace));
}

/// Generate a UUID v3 (namespace + name based with MD5) as ubyte[16]
ubyte[16] UUIDv3(T)(ubyte[] name, ubyte[16] namespace = ubyte[16].init) if (is(T == ubyte))
{
	import std.digest.md : MD5;

	ubyte[16] value;

	// Create MD5 hash of namespace and name
	auto md5 = new MD5();
	md5.start();
	md5.put(namespace);
	md5.put(name);
	ubyte[] hash = md5.finish().dup;

	// Copy first 16 bytes of hash to value
	value[0..16] = hash[0..16];

	// Set version and variant
	value[6] = (value[6] & 0x0f) | 0x30; // Version 3
	value[8] = (value[8] & 0x3f) | 0x80; // Variant 1

	return value;
}

/// Generate a UUID v5 (namespace + name based) as string
string UUIDv5(T = string)(string name, ubyte[16] namespace = ubyte[16].init) if(is(T==string)) {
	import std.string : representation;
	return UUIDv5!string(cast(ubyte[])name.representation, namespace);
}

/// Generate a UUID v5 (namespace + name based) as string
string UUIDv5(T = string)(ubyte[] name, ubyte[16] namespace = ubyte[16].init) if(is(T==string)) {
	return formatUUID(UUIDv5!ubyte(name, namespace));
}

/// Generate a UUID v5 (namespace + name based) as ubyte[16]
ubyte[16] UUIDv5(T)(ubyte[] name, ubyte[16] namespace = ubyte[16].init) if (is(T == ubyte))
{
	import std.digest.sha : SHA1;

	ubyte[16] value;

	// Create SHA1 hash of namespace and name
	auto sha1 = new SHA1();
	sha1.start();
	sha1.put(namespace);
	sha1.put(name);
	ubyte[] hash = sha1.finish().dup;

	// Copy first 16 bytes of hash to value
	value[0..16] = hash[0..16];

	// Set version and variant
	value[6] = (value[6] & 0x0f) | 0x50; // Version 5
	value[8] = (value[8] & 0x3f) | 0x80; // Variant 1

	return value;
}

private:

string formatUUID(ubyte[16] uuid)
{
	import std.string : toLower;
	import std.format : format;
	import std.digest : toHexString;

	char[32] tmp = uuid.toHexString.toLower;
	return format("%s-%s-%s-%s-%s", tmp[0..8], tmp[8..12], tmp[12..16], tmp[16..20], tmp[20..$]);
}

void randomBytes(ubyte[] buffer)
{
	// Random bytes
	version(Windows)
	{
		import core.sys.windows.windows;
		import core.sys.windows.wincrypt;

		HCRYPTPROV hProvider;

		CryptAcquireContext(&hProvider, null, null, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT);
		CryptGenRandom(hProvider, cast(uint)buffer.length, buffer.ptr);
		CryptReleaseContext(hProvider, 0);
	}
	else
	{
		import std.file : read;
		buffer[0..$] = cast(ubyte[])read("/dev/urandom", buffer.length);
	}
}