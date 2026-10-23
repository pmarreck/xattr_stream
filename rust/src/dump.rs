//! The per-file JSON dump format that `dump --json` writes and `load` reads:
//! one object per line, {"path"|"path_pb": str, "xattrs"?: {name: pb},
//! "xattrs_pb"?: {pb-name: pb}}. Pure: parses and classifies bytes, performs
//! no I/O and no printable-binary decoding (callers own both). Port of
//! src/dump.zig.

/// Which part of a dump line a parsed string came from. Values match the C
/// ABI's `XS_DUMP_*` constants.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
	Path = 0,
	PathPb = 1,
	Xattr = 2,
	XattrPb = 3,
}

/// The line is not a dump line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Malformed;

/// Restore-safety classifier: true when `path` is relative and never climbs
/// above its starting directory. Applies the union of POSIX and Windows rules
/// on every OS (a dump can move between systems): rejects empty paths, NUL,
/// a leading / or \ (root, UNC), a drive prefix like `C:`, and any `..`
/// component split on either separator.
pub fn is_contained_relative_path(path: &[u8]) -> bool {
	if path.is_empty() || path.contains(&0) || is_absolute_path(path) {
		return false;
	}
	!path.split(|&c| c == b'/' || c == b'\\').any(|component| component == b"..")
}

/// True for a path anchored outside the current directory under POSIX or
/// Windows rules: a leading / or \ (root, UNC) or a drive prefix like `C:`.
pub fn is_absolute_path(path: &[u8]) -> bool {
	match path {
		[] => false,
		[b'/' | b'\\', ..] => true,
		[letter, b':', ..] => letter.is_ascii_alphabetic(),
		_ => false,
	}
}

/// Parses one dump line and calls `emit(field, key, value)` for the path (key
/// empty) and then each attribute, `xattrs` before `xattrs_pb`, in document
/// order; `emit` returns false to stop. Strict: exactly one of path/path_pb,
/// string values only, no unknown or duplicate keys, and otherwise the JSON
/// rules of Zig's std.json (strict UTF-8, no unpaired surrogate escapes, no
/// raw control characters in strings). Strings are unescaped but otherwise
/// passed through, still printable-binary where the format says so.
///
/// Only one document shape is accepted, so this is a recursive-descent
/// parser for exactly that shape: anything else is Malformed whether or not
/// it is valid JSON, which is what the reference parser concludes as well.
pub fn parse_line(line: &[u8], mut emit: impl FnMut(Field, &[u8], &[u8]) -> bool) -> Result<(), Malformed> {
	// Outside strings JSON is ASCII, and inside them UTF-8 must be valid, so
	// any invalid UTF-8 anywhere makes the line malformed.
	if std::str::from_utf8(line).is_err() {
		return Err(Malformed);
	}
	let mut p = Parser { s: line, i: 0 };
	let mut path: Option<(Field, Vec<u8>)> = None;
	let mut xattrs: Option<Vec<(Vec<u8>, Vec<u8>)>> = None;
	let mut xattrs_pb: Option<Vec<(Vec<u8>, Vec<u8>)>> = None;
	p.ws();
	p.expect(b'{')?;
	p.ws();
	if p.peek() != Some(b'}') {
		loop {
			p.ws();
			let key = p.string()?;
			p.ws();
			p.expect(b':')?;
			p.ws();
			match key.as_slice() {
				b"path" | b"path_pb" => {
					if path.is_some() {
						return Err(Malformed);
					}
					let field = if key.len() == 4 { Field::Path } else { Field::PathPb };
					path = Some((field, p.string()?));
				}
				b"xattrs" => {
					if xattrs.is_some() {
						return Err(Malformed);
					}
					xattrs = Some(p.string_map()?);
				}
				b"xattrs_pb" => {
					if xattrs_pb.is_some() {
						return Err(Malformed);
					}
					xattrs_pb = Some(p.string_map()?);
				}
				_ => return Err(Malformed),
			}
			p.ws();
			match p.next() {
				Some(b',') => continue,
				Some(b'}') => break,
				_ => return Err(Malformed),
			}
		}
	} else {
		p.i += 1;
	}
	p.ws();
	if p.i != line.len() {
		return Err(Malformed);
	}
	let (field, value) = path.ok_or(Malformed)?;
	if !emit(field, b"", &value) {
		return Ok(());
	}
	for (map, field) in [(xattrs, Field::Xattr), (xattrs_pb, Field::XattrPb)] {
		for (k, v) in map.into_iter().flatten() {
			if !emit(field, &k, &v) {
				return Ok(());
			}
		}
	}
	Ok(())
}

struct Parser<'a> {
	s: &'a [u8],
	i: usize,
}

impl Parser<'_> {
	fn peek(&self) -> Option<u8> {
		self.s.get(self.i).copied()
	}

	fn next(&mut self) -> Option<u8> {
		let c = self.peek()?;
		self.i += 1;
		Some(c)
	}

	fn expect(&mut self, c: u8) -> Result<(), Malformed> {
		if self.next() == Some(c) {
			Ok(())
		} else {
			Err(Malformed)
		}
	}

	fn ws(&mut self) {
		while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
			self.i += 1;
		}
	}

	/// An object whose values are all strings, keys unique after unescaping.
	fn string_map(&mut self) -> Result<Vec<(Vec<u8>, Vec<u8>)>, Malformed> {
		self.expect(b'{')?;
		let mut out: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
		self.ws();
		if self.peek() == Some(b'}') {
			self.i += 1;
			return Ok(out);
		}
		loop {
			self.ws();
			let k = self.string()?;
			self.ws();
			self.expect(b':')?;
			self.ws();
			let v = self.string()?;
			if out.iter().any(|(seen, _)| *seen == k) {
				return Err(Malformed);
			}
			out.push((k, v));
			self.ws();
			match self.next() {
				Some(b',') => continue,
				Some(b'}') => return Ok(out),
				_ => return Err(Malformed),
			}
		}
	}

	fn hex4(&mut self) -> Result<u32, Malformed> {
		let mut v = 0u32;
		for _ in 0..4 {
			let d = (self.next().ok_or(Malformed)? as char).to_digit(16).ok_or(Malformed)?;
			v = v << 4 | d;
		}
		Ok(v)
	}

	/// A JSON string, unescaped to UTF-8 bytes. The input is already known to
	/// be valid UTF-8, so non-escape bytes are copied as they are.
	fn string(&mut self) -> Result<Vec<u8>, Malformed> {
		self.expect(b'"')?;
		let mut out = Vec::new();
		loop {
			match self.next().ok_or(Malformed)? {
				b'"' => return Ok(out),
				b'\\' => {
					let c = match self.next().ok_or(Malformed)? {
						b'"' => '"',
						b'\\' => '\\',
						b'/' => '/',
						b'b' => '\u{8}',
						b'f' => '\u{c}',
						b'n' => '\n',
						b'r' => '\r',
						b't' => '\t',
						b'u' => {
							let u = self.hex4()?;
							let cp = match u {
								0xD800..=0xDBFF => {
									// A high surrogate must be followed by an escaped low one.
									self.expect(b'\\')?;
									self.expect(b'u')?;
									let lo = self.hex4()?;
									if !(0xDC00..=0xDFFF).contains(&lo) {
										return Err(Malformed);
									}
									0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
								}
								0xDC00..=0xDFFF => return Err(Malformed),
								_ => u,
							};
							char::from_u32(cp).ok_or(Malformed)?
						}
						_ => return Err(Malformed),
					};
					let mut buf = [0u8; 4];
					out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
				}
				c if c < 0x20 => return Err(Malformed),
				c => out.push(c),
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn contained_relative_paths_over_accept_and_reject_sets() {
		let accept: [&[u8]; 12] = [b"a", b"a/b", b"./a", b"a/./b", b".", b"dir with space/f", b"..a", b"a..", b"a/..b", b"b/c..", b"caf\xe9", b"a/b/"];
		let reject: [&[u8]; 16] = [
			b"", b"/a", b"/", b"//srv/x", b"\\a", b"\\\\srv\\share\\f", b"C:/a", b"c:a", b"Z:\\x", b"a/../b", b"..", b"../a", b"a/..", b"a\\..\\b", b"..\\a", b"a\x00b",
		];
		assert_eq!(accept.iter().filter(|p| is_contained_relative_path(p)).count(), accept.len());
		assert_eq!(reject.iter().filter(|p| !is_contained_relative_path(p)).count(), reject.len());
	}

	#[test]
	fn absolute_paths_over_accept_and_reject_sets() {
		let accept: [&[u8]; 10] = [b"/", b"/a", b"//srv/x", b"\\a", b"\\\\srv\\share\\f", b"C:/a", b"c:a", b"Z:\\x", b"C:", b"a:/b"];
		let reject: [&[u8]; 8] = [b"", b"a", b"./a", b"../a", b"a/b", b"1:a", b"ab:c", b":a"];
		assert_eq!(accept.iter().filter(|p| is_absolute_path(p)).count(), accept.len());
		assert_eq!(reject.iter().filter(|p| !is_absolute_path(p)).count(), reject.len());
	}

	fn record(line: &[u8]) -> Result<String, Malformed> {
		let mut out = String::new();
		parse_line(line, |f, k, v| {
			let tag = match f {
				Field::Path => "path",
				Field::PathPb => "path_pb",
				Field::Xattr => "xattr",
				Field::XattrPb => "xattr_pb",
			};
			out.push_str(&format!("{tag}|{}|{}\n", String::from_utf8_lossy(k), String::from_utf8_lossy(v)));
			true
		})?;
		Ok(out)
	}

	#[test]
	fn emits_the_path_first_then_xattrs_and_xattrs_pb_in_document_order() {
		let cases: [(&str, &str); 6] = [
			(r#"{"xattrs":{"b":"2","a":"1"},"path":"p"}"#, "path||p\nxattr|b|2\nxattr|a|1\n"),
			(r#"{"path_pb":"x","xattrs_pb":{"n":"v"},"xattrs":{"k":"w"}}"#, "path_pb||x\nxattr|k|w\nxattr_pb|n|v\n"),
			(r#"{"path":"p"}"#, "path||p\n"),
			(r#"  {"path":"p","xattrs":{}}  "#, "path||p\n"),
			(r#"{"path":"a\"b","xattrs":{"k":"\u00e9 x"}}"#, "path||a\"b\nxattr|k|\u{e9} x\n"),
			(r#"{ "path" : "\ud83d\ude00\/\t" , "xattrs" : { "" : "" } }"#, "path||\u{1F600}/\t\nxattr||\n"),
		];
		for (line, want) in cases {
			assert_eq!(record(line.as_bytes()).as_deref(), Ok(want), "{line}");
		}
	}

	#[test]
	fn rejects_malformed_lines_as_a_set() {
		let reject: [&[u8]; 30] = [
			b"",
			b"[]",
			b"\"s\"",
			b"{}",
			br#"{"xattrs":{}}"#,
			br#"{"path":"a","path_pb":"b"}"#,
			br#"{"path":1}"#,
			br#"{"path":null}"#,
			br#"{"path":"a","xattrs":[]}"#,
			br#"{"path":"a","xattrs":{"k":1}}"#,
			br#"{"path":"a","extra":1}"#,
			br#"{"path":"a","path":"b"}"#,
			br#"{"path":"a","xattrs":{"k":"1","k":"2"}}"#,
			br#"{"path":"a"} x"#,
			br#"{"path":"a""#,
			br#"{"path":"a","xattrs_pb":{"k":{}}}"#,
			// Beyond the Zig set: the JSON rules the reference parser enforces.
			br#"{"path":"a",}"#,
			br#"{"path":"a","xattrs":{"k":"v",}}"#,
			br#"{"path":"\ud800"}"#,
			br#"{"path":"\udc00"}"#,
			br#"{"path":"\ud800\u0041"}"#,
			br#"{"path":"\x"}"#,
			br#"{"path":"\u12g4"}"#,
			b"{\"path\":\"a\tb\"}",
			b"{\"path\":\"caf\xe9\"}",
			b"\xef\xbb\xbf{\"path\":\"a\"}",
			br#"{"path":"a","xattrs":{"k":"1","\u006b":"2"}}"#,
			br#"{"path":"a","xattrs":{},"xattrs":{}}"#,
			br#"{'path':'a'}"#,
			br#"{"path":"a"}}"#,
		];
		for line in reject {
			let mut seen = 0;
			assert_eq!(parse_line(line, |_, _, _| { seen += 1; true }), Err(Malformed), "{}", String::from_utf8_lossy(line));
			assert_eq!(seen, 0);
		}
	}

	#[test]
	fn stops_when_the_callback_returns_false() {
		let mut seen = 0;
		parse_line(br#"{"path":"p","xattrs":{"a":"1","b":"2","c":"3"}}"#, |_, _, _| {
			seen += 1;
			seen < 2
		})
		.unwrap();
		assert_eq!(seen, 2);
	}
}
