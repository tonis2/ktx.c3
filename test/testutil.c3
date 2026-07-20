// Shared helpers for the test suite.
module ktx_testutil;
import std::math;

<*
 Peak signal-to-noise ratio between two equal-length RGBA8 buffers, in dB.
 Identical buffers return infinity. Tracks encoder quality against the basisu
 reference during the pure-C3 rewrite (docs/basis-rewrite.md) — recorded, not
 gated on.
*>
fn double psnr(char[] a, char[] b)
{
	assert(a.len == b.len && a.len > 0, "psnr needs equal non-empty buffers");
	double sum = 0;
	foreach (i, x : a)
	{
		double d = (double)x - (double)b[i];
		sum += d * d;
	}
	if (sum == 0) return bitcast((ulong)0x7ff0_0000_0000_0000, double);   // +inf
	double mse = sum / (double)a.len;
	return 10.0 * math::log10(255.0 * 255.0 / mse);
}

module testutil_tests @test;
import ktx_testutil;
import std::math;

fn void psnr_identical_is_inf()
{
	char[4] a = { 1, 2, 3, 4 };
	assert(math::is_inf(ktx_testutil::psnr(a[..], a[..])));
}

fn void psnr_known_values()
{
	// Every byte off by 255: MSE = 255^2, PSNR = 0 dB.
	char[4] black = { 0, 0, 0, 0 };
	char[4] white = { 255, 255, 255, 255 };
	assert(math::abs(ktx_testutil::psnr(black[..], white[..])) < 1e-9);

	// Every byte off by one: PSNR = 10*log10(255^2) ~= 48.13 dB.
	char[4] one = { 1, 1, 1, 1 };
	double db = ktx_testutil::psnr(black[..], one[..]);
	assert(math::abs(db - 48.1308036) < 1e-4, "got %f", db);
}
