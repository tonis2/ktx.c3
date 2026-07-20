// Little-endian byte helpers shared by the KTX2 container modules.
// KTX2 files are always little-endian.
module ktx::util;

fn void wr32(char[] buf, sz offset, uint v) @inline
{
	buf[offset] = (char)v;
	buf[offset + 1] = (char)(v >> 8);
	buf[offset + 2] = (char)(v >> 16);
	buf[offset + 3] = (char)(v >> 24);
}

fn void wr64(char[] buf, sz offset, ulong v) @inline
{
	wr32(buf, offset, (uint)v);
	wr32(buf, offset + 4, (uint)(v >> 32));
}

fn uint rd16(char[] buf, sz offset) @inline
{
	return (uint)buf[offset] | (uint)buf[offset + 1] << 8;
}

fn uint rd32(char[] buf, sz offset) @inline
{
	return (uint)buf[offset]
		| (uint)buf[offset + 1] << 8
		| (uint)buf[offset + 2] << 16
		| (uint)buf[offset + 3] << 24;
}

fn ulong rd64(char[] buf, sz offset) @inline
{
	return (ulong)rd32(buf, offset) | (ulong)rd32(buf, offset + 4) << 32;
}

<* Bytes needed on top of `n` to reach a multiple of `align`. *>
fn sz pad_len(sz align, sz n) @inline
{
	return (align - n % align) % align;
}

<* Least common multiple of `x` and 4 (level alignment rule from the KTX2 spec). *>
fn sz lcm4(sz x) @inline
{
	if (x % 4 == 0) return x;
	if (x % 2 == 0) return x * 2;
	return x * 4;
}
