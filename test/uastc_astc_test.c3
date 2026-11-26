// UASTC -> ASTC 4x4 mapper. The independent oracle is Arm's astcenc, run by
// test/astc-validate.sh; these pin what it accepted, and the two facts the
// mapper relies on, without needing it installed.
module uastc_astc_testutil;
import ktx::uastc;

<* Bits an integer sequence of `count` values takes at `range`. *>
fn uint ise_bits(uint count, uint range)
{
	uint bits = uastc::BISE_RANGE[range][0] * count;
	if (uastc::BISE_RANGE[range][1]) bits += (8 * count + 4) / 5;
	if (uastc::BISE_RANGE[range][2]) bits += (7 * count + 2) / 3;
	return bits;
}

module uastc_astc_tests @test;
import ktx::uastc, ktx::uastc_astc;
import uastc_astc_testutil;

struct Pair
{
	char[] uastc;
	char[] astc;
}

// One random valid block per UASTC mode (test/astc-validate.sh's generator,
// seed 1, blocks 57..75) and its ASTC block, which astcenc decodes to exactly
// the pixels uastc::decode_block gives.
const Pair[19] PAIRS = {
	{ x"81438a6a97f49f90788a9a4022506121", x"420225767e3a52227b79f5bbfda6aed1" }, // mode 0
	{ x"b52b8b8fefa7f3e0971dbcd9d2e5b409", x"4200f9f87e3a0f7e01000000b4d9831b" }, // mode 1
	{ x"3dd052f629ae9be65ce8fd91d86dfa75", x"532801709fe29afa461cd024923bae14" }, // mode 2
	{ x"831d42d355e626de66e0b0de685549f9", x"42f01690ea5b85d3889f940c5759364b" }, // mode 3
	{ x"b390c2603de74d337476d058efb95919", x"42083e50dd0e91972b1b5013cdce7b1a" }, // mode 4
	{ x"2b35c992b54a95ac2f5585e5bfd1d56e", x"530059b256a992f501005dec3f0d5545" }, // mode 5
	{ x"fbb20a7ea38bbb1a29bf1df04b317caa", x"4204f50bae2b0d0a553e8cd20fb8fd24" }, // mode 6
	{ x"476b9b4a302e0d8141e3f27f753b6704", x"426826108ac8c50cb3f2bb06736e6890" }, // mode 7
	{ x"d771b49c509622df86c0fe66b55051e6", x"fcfdffffffffffff8e8ea3a3e5e58484" }, // mode 8
	{ x"cfbda104bce02e28451a6b332d8787db", x"428803b8fc202e49a4b136131d0080c2" }, // mode 9
	{ x"22cfa6cf5a4aaffcc8153790460d5fc8", x"4282c54e15e5b83cec054f9df61357dc" }, // mode 10
	{ x"98f8ce563bb3e26deb1e8936c5aa3b44", x"42847d96e9e8dc5b22dc55a36c917827" }, // mode 11
	{ x"de9373d6c275156185d6a3ee6d40318c", x"5380d7c244ab4a383d3ace73fd49887a" }, // mode 12
	{ x"7f0b19ea5785e4e1390873d6f673e6af", x"41842bbe0e2541ceb3980180801903c9" }, // mode 13
	{ x"8d7298c47e444afc064253884965113c", x"42808fd8894941de0a690000becb6af3" }, // mode 14
	{ x"0516b8b935af570a9d9aad152b670d22", x"4282ac79bd52000008d69c1ab5362b27" }, // mode 15
	{ x"5530a32ad97e36e94d0cc8896b158536", x"428819c8f6b3496f62404e1c6ca1a82a" }, // mode 16
	{ x"657055c2dd400d552449a7994de88181", x"4284dc0dd45001c00cbc90cd2c972421" }, // mode 17
	{ x"49533c5e39fabe56eeee1c578865291d", x"53028f578e3eb894a611ea3877776af5" }, // mode 18
};

fn void every_mode_maps_to_the_recorded_block()
{
	foreach (m, pair : PAIRS)
	{
		uastc::Unpacked u;
		uastc::unpack_block(pair.uastc, &u)!!;
		assert(u.mode == m, "pair %d holds mode %d", m, u.mode);
		char[16] got;
		uastc_astc::map_block(pair.uastc, &got[0]);
		assert(got[..] == pair.astc, "mode %d mapped to a different block", m);
	}
}

fn void every_pattern_has_an_astc_seed()
{
	assert(uastc_astc::every_pattern_has_a_seed());
	// Pattern 0 is BC7's first: the left half against the right.
	uastc_astc::Partition p = uastc_astc::partition(2, 0);
	for (uint i = 0; i < 16; i++)
	{
		uint astc = uastc_astc::select_partition(p.seed, i % 4, i / 4, 2);
		assert(p.subset[astc] == uastc::PATTERNS2[i]);
	}
}

// An ASTC decoder never reads the endpoint range: it takes the largest one the
// bits left over hold. The mapper copies UASTC's, so the two must agree.
fn void each_mode_range_is_the_one_astc_derives()
{
	for (uint m = 0; m < uastc::TOTAL_MODES; m++)
	{
		if (m == uastc::MODE_SOLID) continue;
		uint weights = 16 * uastc::MODE_PLANES[m] * uastc::MODE_WEIGHT_BITS[m];
		uint subsets = uastc::MODE_SUBSETS[m];
		uint left = (subsets == 1 ? 111 : 99) - weights - (uastc::MODE_PLANES[m] == 2 ? 2 : 0);
		uint values = uastc::MODE_COMPS[m] * 2 * subsets;
		uint derived;
		for (uint r = 0; r <= 20; r++)
		{
			if (uastc_astc_testutil::ise_bits(values, r) <= left) derived = r;
		}
		assert(derived == uastc::MODE_ENDPOINT_RANGES[m], "mode %d: ASTC reads range %d, UASTC has %d",
			m, derived, uastc::MODE_ENDPOINT_RANGES[m]);
	}
}

fn void a_short_payload_is_refused()
{
	char[16] one;
	assert(@catch(uastc_astc::map_image(mem, one[..], 8, 8)) == uastc_astc::INVALID_SIZE);
}
