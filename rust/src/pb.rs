//! printable-binary codec: every byte maps to one printable UTF-8 glyph, ASCII
//! letters, digits and `. @ ^ _` map to themselves, so text stays legible.
//! Byte-for-byte port of the pinned printable_binary encode/decode (the C ABI
//! `pb_encode`/`pb_decode` the C CLI uses) for the two modes this project
//! needs: encoding with literal spaces preserved, and default decoding, where
//! a literal space decodes as a space and anything outside the alphabet passes
//! through unchanged.
use crate::pb_map::GLYPHS;
use std::sync::OnceLock;

/// Encode with spaces kept literal (`PB_ENCODE_PRESERVE_SPACES`), so text
/// values stay readable while every other byte is unambiguous.
pub fn encode_preserving_spaces(input: &[u8]) -> Vec<u8> {
	let mut out = Vec::with_capacity(input.len() * 3);
	for &b in input {
		if b == b' ' {
			out.push(b' ');
		} else {
			out.extend_from_slice(GLYPHS[b as usize]);
		}
	}
	out
}

struct Tables {
	one: [i16; 256],
	/// Indexed by (lead & 0x1F, trail & 0x3F), as the reference decoder does:
	/// it does not check that the trail byte is a continuation byte.
	two: [[i16; 64]; 32],
	/// Sorted (glyph bytes as u32, byte value).
	three: Vec<(u32, u8)>,
}

fn tables() -> &'static Tables {
	static T: OnceLock<Tables> = OnceLock::new();
	T.get_or_init(|| {
		let mut t = Tables { one: [-1; 256], two: [[-1; 64]; 32], three: Vec::new() };
		for (byte, g) in GLYPHS.iter().enumerate() {
			match g.len() {
				1 => t.one[g[0] as usize] = byte as i16,
				2 => t.two[(g[0] & 0x1F) as usize][(g[1] & 0x3F) as usize] = byte as i16,
				3 => t.three.push((u32::from(g[0]) << 16 | u32::from(g[1]) << 8 | u32::from(g[2]), byte as u8)),
				n => panic!("glyph for byte {byte} is {n} bytes"),
			}
		}
		t.three.sort_unstable();
		t
	})
}

/// UTF-8 sequence length from the lead byte, as the reference decoder judges
/// it (continuation bytes count as two-byte leads).
fn seq_len(b: u8) -> usize {
	if b < 0x80 {
		1
	} else if b < 0xE0 {
		2
	} else if b < 0xF0 {
		3
	} else {
		4
	}
}

/// Decode printable-binary back to bytes (`PB_DECODE_NONE`). Unrecognized
/// or truncated sequences are copied through unchanged.
pub fn decode(input: &[u8]) -> Vec<u8> {
	let t = tables();
	let mut out = Vec::with_capacity(input.len());
	let mut i = 0;
	while i < input.len() {
		let want = seq_len(input[i]);
		let len = want.min(input.len() - i);
		if len == want {
			let hit = match len {
				1 => t.one[input[i] as usize],
				2 => t.two[(input[i] & 0x1F) as usize][(input[i + 1] & 0x3F) as usize],
				3 => {
					let key = u32::from(input[i]) << 16 | u32::from(input[i + 1]) << 8 | u32::from(input[i + 2]);
					t.three.binary_search_by_key(&key, |&(k, _)| k).map_or(-1, |at| i16::from(t.three[at].1))
				}
				_ => -1,
			};
			if hit >= 0 {
				out.push(hit as u8);
				i += len;
				continue;
			}
		}
		out.extend_from_slice(&input[i..i + len]);
		i += len;
	}
	out
}

#[cfg(test)]
mod tests {
	use super::*;

	/// Produced by printable_binary's LuaJIT implementation (`-s`), not by this
	/// code: an independent oracle for the whole table.
	const ALL_BYTES_PB: &[u8] = include_bytes!("../../tests/cli/fixtures/allbytes.pb");

	fn all_bytes() -> Vec<u8> {
		(0..=255u8).collect()
	}

	#[test]
	fn encoding_all_256_bytes_matches_the_independent_fixture() {
		assert_eq!(encode_preserving_spaces(&all_bytes()), ALL_BYTES_PB);
	}

	#[test]
	fn decoding_the_fixture_restores_all_256_bytes() {
		assert_eq!(decode(ALL_BYTES_PB), all_bytes());
	}

	#[test]
	fn every_byte_round_trips_alone_and_glyphs_are_distinct_valid_utf8() {
		let mut seen = std::collections::HashSet::new();
		for b in 0..=255u8 {
			let e = encode_preserving_spaces(&[b]);
			assert!(std::str::from_utf8(&e).is_ok(), "byte {b:#04x}");
			assert_eq!(decode(&e), vec![b], "byte {b:#04x}");
			assert!(seen.insert(e), "byte {b:#04x} shares a glyph");
			// The other direction: each glyph decodes to one byte that encodes
			// back to that glyph (space is the one literal exception).
			let g = GLYPHS[b as usize];
			assert_eq!(encode_preserving_spaces(&decode(g)), if b == b' ' { b" ".to_vec() } else { g.to_vec() });
		}
	}

	#[test]
	fn every_byte_pair_round_trips() {
		for a in 0..=255u8 {
			for b in 0..=255u8 {
				assert_eq!(decode(&encode_preserving_spaces(&[a, b])), vec![a, b]);
			}
		}
	}

	#[test]
	fn decode_passes_through_text_outside_the_alphabet() {
		// ASCII passthrough letters decode to themselves; a literal space is a
		// space; characters with no mapping and a truncated tail pass through.
		assert_eq!(decode(b"abc XYZ 019"), b"abc XYZ 019");
		assert_eq!(decode("\u{1F600}".as_bytes()), "\u{1F600}".as_bytes());
		assert_eq!(decode(b"\xe2\x90"), b"\xe2\x90");
		assert_eq!(decode(b""), b"");
	}
}
