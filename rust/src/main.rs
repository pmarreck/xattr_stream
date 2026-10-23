//! xattr-stream-rs: the Rust implementation of the xattr-stream CLI. Same
//! commands, options, output bytes and exit codes as the C CLI
//! (src/xattr_stream_cli.c); the Bash suite in tests/cli runs against both,
//! and tests/cli/differential compares them on the same fixtures.
//!
//! Exit codes: 0 ok, 1 other error, 2 usage, 3 unsupported filesystem,
//! 4 missing attribute (get), 5 permission/read-only, 6 too large,
//! 7 path not found, 8 invalid name or path.
use std::ffi::OsString;
use std::io::{self, BufWriter, IsTerminal, Read, Write};
use xattr_stream::{self as xs, dump, names, pb, walk, Error, Options, Status, PORTABLE_VALUE_LEN};

const PROG: &str = "xattr-stream";
const ANSI_NAME: &[u8] = b"\x1b[38;5;208m";
const ANSI_VALUE: &[u8] = b"\x1b[38;5;117m";
const ANSI_RESET: &[u8] = b"\x1b[0m";
const ELLIPSIS: &[u8] = "\u{2026}".as_bytes();

const EXIT_OK: i32 = 0;
const EXIT_ERROR: i32 = 1;
const EXIT_USAGE: i32 = 2;

const USAGE: &str = concat!(
	"Usage:\n",
	"  xattr-stream [options] put|set <path> <name>   value from stdin\n",
	"  xattr-stream [options] get <path> <name>       value to stdout\n",
	"  xattr-stream [options] len <path> <name>       byte length, or -1 if missing\n",
	"  xattr-stream [options] del <path> <name>       delete (no error if missing)\n",
	"  xattr-stream [options] lst|list <path>         names, one per line\n",
	"  xattr-stream [options] dmp|dump <path>         names and values (alias: lst --values)\n",
	"  xattr-stream [options] lim|limits [<path>]     max value bytes on that filesystem, or -1\n",
	"  xattr-stream [options] load [<file>|-|@stdin]  restore a --json dump (stdin by default)\n",
	"  xattr-stream --help | -h | --version | --about\n",
	"\n",
	"Options (any order, before or after the command; -- ends options):\n",
	"  --nofollow      operate on a symlink itself, not its target\n",
	"  --raw           use native OS names (e.g. Linux user.x, macOS com.apple.x)\n",
	"  --limit <n>     max value size in bytes for put/get (default 65536, the\n",
	"                  smallest OS ceiling; macOS and NTFS allow more)\n",
	"  --json          JSON on stdout for len/lst/limits and JSON errors on stderr;\n",
	"                  dump writes one {\"path\",\"xattrs\"} object per file per line,\n",
	"                  values always printable-binary (the format load reads)\n",
	"  --quiet         suppress warnings (e.g. values over 3916 bytes)\n",
	"  --root <dir>    load: resolve relative dump paths against <dir>\n",
	"  --allow-unsafe-paths  load: accept absolute paths and .. components\n",
	"  -r, --recurse   lst/dump: walk the tree below <path>, breadth-first\n",
	"  -d, --depth <n> lst/dump: limit the walk to n levels (0 = <path> alone);\n",
	"                  implies --recurse; also -d=<n> / --depth=<n>\n",
	"  --depth-first   lst/dump: walk depth-first (pre-order) instead\n",
	"  --values        lst: show values through printable-binary (one reversible\n",
	"                  line per value; decode with `printable-binary -d`)\n",
	"  --hex           show values as lowercase hex instead of printable-binary\n",
	"  --utf8          show values that are printable single-line UTF-8 verbatim and\n",
	"                  add a type column (utf8 | pb | hex)\n",
	"  --tsv           tab-separated rows, no header (default)\n",
	"  --csv           comma-separated rows with a header; names and values go\n",
	"                  through printable-binary so no delimiter can appear\n",
	"  --table         ASCII table; paths truncate on the left, other cells on the\n",
	"                  right (default widths: path 48, name 24, type 4, value 40)\n",
	"  --md, --markdown  Markdown table with the same widths\n",
	"  --cols <a,b,..> column widths in display order ([path,] name, [type,] value);\n",
	"                  0 = no truncation; implies --table unless --md is given\n",
	"  -w, --max-width <n>  cut displayed values after n characters, appending\n",
	"                  ...(N bytes); 0 = unlimited; never applies to --json\n",
	"  --debug         also report what a recursive walk skipped: dangling symlinks\n",
	"                  and entries deleted mid-walk (or set the DEBUG env var)\n",
	"  --color         force ANSI color in listings (default: only on a terminal,\n",
	"                  and never when NO_COLOR is set)\n",
	"  --no-color      never emit ANSI (aliases: --no-ansi, --simple)\n",
	"\n",
	"Listing columns: [path] name [type] value. The path column appears when\n",
	"recursing, the value with --values/dump, the type only with --utf8.\n",
	"Children are visited in bytewise order; symlinks are listed but never entered.\n",
	"\n",
	"Names: 1..127 bytes UTF-8, no control chars or / \\ : * ? \" < > |, no\n",
	"leading/trailing space or trailing dot, not $..., com.apple..., Zone.Identifier,\n",
	"and not starting with user. (Linux stores every name as user.<name> itself;\n",
	"macOS and Windows NTFS streams store it verbatim).\n",
	"Values over 3916 bytes draw a warning: ext4 without ea_inode keeps all of a\n",
	"file's attributes in one 4 KiB block, which holds 3916 bytes of value next to\n",
	"the longest valid name.\n",
	"\n",
	"Windows (or OS=mswin): lines end with CRLF, and options may also be written\n",
	"/name, /name:value or /? (a path such as /dir then needs -- or \\dir).\n",
	"\n",
	"Exit codes: 0 ok, 1 error, 2 usage, 3 unsupported fs, 4 missing, 5 permission,\n",
	"6 too large, 7 path not found, 8 invalid name/path.\n",
);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Fmt {
	Tsv,
	Csv,
	Table,
	Md,
}

const MAX_COLS: usize = 4;

struct Cli {
	/// The --limit value as given (0 included); the core maps 0 to the default.
	limit: u64,
	nofollow: bool,
	raw: bool,
	json: bool,
	fmt: Fmt,
	utf8: bool,
	cols: Vec<usize>,
	quiet: bool,
	recurse: bool,
	/// -1 = unlimited; 0 = the path alone.
	max_depth: i64,
	depth_first: bool,
	values: bool,
	debug: bool,
	hex: bool,
	max_width: usize,
	/// -1 auto (terminal and no NO_COLOR), 0 off, 1 forced.
	color: i32,
	use_color: bool,
	root: Option<Vec<u8>>,
	allow_unsafe_paths: bool,
}

impl Cli {
	/// Options for the core, mapping a zero limit to the default as the C ABI
	/// does for `max_value_len == 0`.
	fn xs(&self) -> Options {
		let max = if self.limit == 0 { xs::DEFAULT_MAX_VALUE_LEN } else { usize::try_from(self.limit).unwrap_or(usize::MAX) };
		Options { follow_symlinks: !self.nofollow, raw_names: self.raw, max_value_len: max }
	}
}

fn status(e: Error) -> i32 {
	Status::of(Some(e)).code()
}

fn exit_for(st: i32) -> i32 {
	match st {
		0 => 0,
		2 => 3,
		1 => 4,
		4 | 3 => 5,
		5 => 6,
		6 => 7,
		7 | 8 => 8,
		_ => 1,
	}
}

fn explain(st: i32) -> &'static str {
	match st {
		1 => "attribute not present",
		2 => "filesystem does not support attributes (not evidence of tampering)",
		3 => "filesystem is read-only",
		4 => "permission denied",
		5 => "value exceeds the size limit",
		6 => "path not found",
		7 => "invalid attribute name",
		8 => "invalid path",
		9 => "value kept changing while reading",
		10 => "buffer too small",
		11 => "out of memory",
		13 => "invalid argument",
		_ => "I/O error",
	}
}

/// Windows conventions: text lines end with CRLF and switches may also be
/// spelled /name. They apply on the effective platform mswin: the OS
/// environment variable when it names a platform (linux, macos or mswin),
/// else the one this binary was built for. Windows itself sets
/// OS=Windows_NT, which names none, so a Windows build stays mswin and other
/// builds can simulate it. Decided once, at startup.
static WINDOWS: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

fn windows() -> bool {
	*WINDOWS.get_or_init(|| match std::env::var_os("OS").as_deref().and_then(|v| v.to_str()) {
		Some("mswin") => true,
		Some("linux" | "macos") => false,
		_ => cfg!(windows),
	})
}

/// Text output: each LF becomes CRLF under Windows conventions. Every text
/// write goes through text_stdout or text_stderr; only the raw value bytes of
/// `get` use raw_stdout. A test below pins those three as the only places
/// that open the streams.
struct Text<W: Write>(W);

impl<W: Write> Write for Text<W> {
	fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
		if !windows() {
			return self.0.write(buf);
		}
		for (k, line) in buf.split(|&c| c == b'\n').enumerate() {
			if k > 0 {
				self.0.write_all(b"\r\n")?;
			}
			self.0.write_all(line)?;
		}
		Ok(buf.len())
	}

	fn flush(&mut self) -> io::Result<()> {
		self.0.flush()
	}
}

fn text_stdout() -> Text<io::StdoutLock<'static>> {
	Text(io::stdout().lock())
}

fn text_stderr() -> Text<io::Stderr> {
	Text(io::stderr())
}

fn raw_stdout() -> io::StdoutLock<'static> {
	io::stdout().lock()
}

/// Writes a whole message to stderr in one call, as the C CLI's unbuffered
/// stderr does line by line.
fn eput(bytes: &[u8]) {
	let _ = text_stderr().write_all(bytes);
}

fn json_string(out: &mut Vec<u8>, s: &[u8]) {
	out.push(b'"');
	for &c in s {
		match c {
			b'"' | b'\\' => out.extend_from_slice(&[b'\\', c]),
			c if c < 0x20 => out.extend_from_slice(format!("\\u{c:04x}").as_bytes()),
			c => out.push(c),
		}
	}
	out.push(b'"');
}

/// "key":"bytes" when the bytes are UTF-8, else "key_pb":"<printable-binary>",
/// because JSON cannot carry invalid UTF-8.
fn json_field_utf8_or_pb(out: &mut Vec<u8>, key: &str, s: &[u8]) {
	if xs::is_utf8(s) {
		out.extend_from_slice(format!("\"{key}\":").as_bytes());
		json_string(out, s);
	} else {
		out.extend_from_slice(format!("\"{key}_pb\":").as_bytes());
		json_string(out, &pb::encode_preserving_spaces(s));
	}
}

fn warn_portability(o: &Cli, len: usize) {
	if o.quiet || len <= PORTABLE_VALUE_LEN {
		return;
	}
	let msg = if o.json {
		format!("{{\"warning\":\"portability\",\"bytes\":{len},\"portable_max\":{PORTABLE_VALUE_LEN},\"message\":\"values over {PORTABLE_VALUE_LEN} bytes may not fit on ext4 without the ea_inode feature\"}}\n")
	} else {
		format!("{PROG}: warning: value is {len} bytes; values over {PORTABLE_VALUE_LEN} bytes may not fit on ext4 without the ea_inode feature\n")
	};
	eput(msg.as_bytes());
}

fn report(o: &Cli, op: &str, path: Option<&[u8]>, name: Option<&[u8]>, st: i32) {
	let sname = xs::status_name(st);
	let os_err = xs::last_os_error();
	let reason = match name {
		Some(n) if st == Status::InvalidName.code() => names::classify(xs::OS, n, o.raw),
		_ => None,
	};
	let mut m = Vec::new();
	if o.json {
		m.extend_from_slice(b"{\"status\":");
		json_string(&mut m, sname.as_bytes());
		m.extend_from_slice(b",\"op\":");
		json_string(&mut m, op.as_bytes());
		if let Some(p) = path {
			m.push(b',');
			json_field_utf8_or_pb(&mut m, "path", p);
		}
		if let Some(n) = name {
			m.push(b',');
			json_field_utf8_or_pb(&mut m, "name", n);
		}
		m.extend_from_slice(format!(",\"os_error\":{os_err},\"message\":").as_bytes());
		json_string(&mut m, explain(st).as_bytes());
		if let Some(r) = reason {
			m.extend_from_slice(b",\"reason\":");
			json_string(&mut m, rejection_name(r).as_bytes());
			m.extend_from_slice(b",\"reason_message\":");
			json_string(&mut m, names::rejection_message(r).as_bytes());
		}
		m.extend_from_slice(b"}\n");
	} else {
		m.extend_from_slice(format!("{PROG}: {op}: ").as_bytes());
		m.extend_from_slice(path.unwrap_or(b""));
		if let Some(n) = name {
			m.extend_from_slice(b": ");
			m.extend_from_slice(n);
		}
		m.extend_from_slice(format!(": {sname}: {} (os error {os_err})\n", explain(st)).as_bytes());
		if let Some(r) = reason {
			m.extend_from_slice(format!("{PROG}: {}\n", names::rejection_message(r)).as_bytes());
		}
	}
	eput(&m);
}

fn rejection_name(r: names::Rejection) -> &'static str {
	use names::Rejection::*;
	match r {
		Empty => "XS_NAME_EMPTY",
		TooLong => "XS_NAME_TOO_LONG",
		ControlChar => "XS_NAME_CONTROL_CHAR",
		ForbiddenChar => "XS_NAME_FORBIDDEN_CHAR",
		Reserved => "XS_NAME_RESERVED",
		NotUtf8 => "XS_NAME_NOT_UTF8",
		EdgeWhitespaceOrDot => "XS_NAME_EDGE_WHITESPACE_OR_DOT",
		LinuxNamespace => "XS_NAME_LINUX_NAMESPACE",
		InvalidNative => "XS_NAME_INVALID_NATIVE",
	}
}

/// Reads stdin, bounded: stops as soon as more than `limit` bytes arrived.
fn read_stdin(limit: u64) -> Result<Vec<u8>, i32> {
	let mut buf = Vec::new();
	let cap = limit.saturating_add(1);
	match io::stdin().lock().take(cap).read_to_end(&mut buf) {
		Ok(_) if buf.len() as u64 > limit => Err(Status::TooLarge.code()),
		Ok(_) => Ok(buf),
		Err(_) => Err(Status::Io.code()),
	}
}

fn cmd_put(o: &Cli, path: &[u8], name: &[u8]) -> i32 {
	let buf = match read_stdin(o.limit) {
		Ok(b) => b,
		Err(st) => {
			report(o, "put", Some(b"<stdin>"), None, st);
			return exit_for(st);
		}
	};
	warn_portability(o, buf.len());
	match xs::set(path, name, &buf, &o.xs()) {
		Ok(()) => EXIT_OK,
		Err(e) => {
			report(o, "put", Some(path), Some(name), status(e));
			exit_for(status(e))
		}
	}
}

fn cmd_get(o: &Cli, path: &[u8], name: &[u8]) -> i32 {
	let v = match xs::get(path, name, &o.xs()) {
		Ok(v) => v,
		Err(e) => {
			report(o, "get", Some(path), Some(name), status(e));
			return exit_for(status(e));
		}
	};
	let mut out = raw_stdout();
	if out.write_all(&v).and_then(|()| out.flush()).is_err() {
		report(o, "get", Some(b"<stdout>"), None, Status::Io.code());
		return EXIT_ERROR;
	}
	EXIT_OK
}

fn cmd_len(o: &Cli, path: &[u8], name: &[u8]) -> i32 {
	let line = match xs::size(path, name, &o.xs()) {
		Err(Error::Missing) => (if o.json { "{\"len\":-1}" } else { "-1" }).to_string(),
		Err(e) => {
			report(o, "len", Some(path), Some(name), status(e));
			return exit_for(status(e));
		}
		Ok(n) if o.json => format!("{{\"len\":{n}}}"),
		Ok(n) => n.to_string(),
	};
	println_out(line.as_bytes())
}

fn println_out(line: &[u8]) -> i32 {
	let mut out = text_stdout();
	match out.write_all(line).and_then(|()| out.write_all(b"\n")).and_then(|()| out.flush()) {
		Ok(()) => EXIT_OK,
		Err(_) => EXIT_ERROR,
	}
}

fn cmd_del(o: &Cli, path: &[u8], name: &[u8]) -> i32 {
	match xs::remove(path, name, &o.xs()) {
		Ok(()) | Err(Error::Missing) => EXIT_OK,
		Err(e) => {
			report(o, "del", Some(path), Some(name), status(e));
			exit_for(status(e))
		}
	}
}

// ---- listing (single path or walked tree) ---------------------------------

const COL_PATH: usize = 0;
const COL_NAME: usize = 1;
const COL_TYPE: usize = 2;
const COL_VALUE: usize = 3;
const COL_LABEL: [&str; 4] = ["path", "name", "type", "value"];
const COL_DEFAULT_WIDTH: [usize; 4] = [48, 24, 4, 40];

struct Lst<'a, W: Write> {
	o: &'a Cli,
	out: W,
	json_first: bool,
	failures: usize,
	present: [bool; 4],
	/// 0 = no truncation, no padding.
	width: [usize; 4],
}

fn hex(p: &[u8]) -> Vec<u8> {
	const HX: &[u8; 16] = b"0123456789abcdef";
	p.iter().flat_map(|&b| [HX[(b >> 4) as usize], HX[(b & 15) as usize]]).collect()
}

/// Code points in UTF-8: every byte that is not a 10xxxxxx continuation.
fn utf8_count(p: &[u8]) -> usize {
	p.iter().filter(|&&b| b & 0xC0 != 0x80).count()
}

/// Byte length of the first `max_chars` code points.
fn utf8_prefix_bytes(p: &[u8], max_chars: usize) -> usize {
	let mut chars = 0;
	for (i, &b) in p.iter().enumerate() {
		if b & 0xC0 != 0x80 {
			if chars == max_chars {
				return i;
			}
			chars += 1;
		}
	}
	p.len()
}

/// Byte offset where the last `max_chars` code points begin.
fn utf8_suffix_start(p: &[u8], max_chars: usize) -> usize {
	let mut chars = 0;
	for i in (0..p.len()).rev() {
		if p[i] & 0xC0 != 0x80 {
			chars += 1;
			if chars == max_chars {
				return i;
			}
		}
	}
	0
}

/// A displayed value: its representation ("utf8", "pb" or "hex") and bytes.
fn render_value(o: &Cli, raw: &[u8]) -> (&'static str, Vec<u8>) {
	// CSV always uses printable-binary so no delimiter can appear in a value.
	if o.utf8 && o.fmt != Fmt::Csv && xs::is_display_text(raw) {
		return ("utf8", raw.to_vec());
	}
	if !o.hex {
		return ("pb", pb::encode_preserving_spaces(raw));
	}
	("hex", hex(raw))
}

/// Truncate to `width` code points (0 = unlimited): paths keep their end
/// (left ellipsis), everything else keeps its start.
fn fit_cell(s: &[u8], width: usize, keep_end: bool) -> Vec<u8> {
	if width == 0 || utf8_count(s) <= width {
		return s.to_vec();
	}
	let keep = width - 1;
	if keep_end {
		let start = if keep == 0 { s.len() } else { utf8_suffix_start(s, keep) };
		return [ELLIPSIS, &s[start..]].concat();
	}
	[&s[..utf8_prefix_bytes(s, keep)], ELLIPSIS].concat()
}

/// Replace every | with `repl` (table: U+2223 DIVIDES, markdown: \|) so a
/// cell can never break the frame.
fn escape_bars(s: &[u8], repl: &[u8]) -> Vec<u8> {
	let mut out = Vec::with_capacity(s.len());
	for &c in s {
		if c == b'|' {
			out.extend_from_slice(repl);
		} else {
			out.push(c);
		}
	}
	out
}

/// CSV field per RFC 4180: quoted when it holds a comma, quote, CR or LF.
fn csv_field(out: &mut Vec<u8>, s: &[u8]) {
	if !s.iter().any(|c| matches!(c, b',' | b'"' | b'\n' | b'\r')) {
		out.extend_from_slice(s);
		return;
	}
	out.push(b'"');
	for &c in s {
		if c == b'"' {
			out.push(b'"');
		}
		out.push(c);
	}
	out.push(b'"');
}

impl<W: Write> Lst<'_, W> {
	fn put(&mut self, b: &[u8]) {
		let _ = self.out.write_all(b);
	}

	fn warn_path(&mut self, path: &[u8], name: Option<&[u8]>, st: i32) {
		self.failures += 1;
		if self.o.quiet {
			return;
		}
		let sname = xs::status_name(st);
		let mut m = Vec::new();
		if self.o.json {
			m.extend_from_slice(b"{\"warning\":");
			json_string(&mut m, sname.as_bytes());
			m.push(b',');
			json_field_utf8_or_pb(&mut m, "path", path);
			if let Some(n) = name {
				m.push(b',');
				json_field_utf8_or_pb(&mut m, "name", n);
			}
			m.extend_from_slice(format!(",\"os_error\":{},\"message\":", xs::last_os_error()).as_bytes());
			json_string(&mut m, explain(st).as_bytes());
			m.extend_from_slice(b"}\n");
		} else {
			m.extend_from_slice(format!("{PROG}: warning: ").as_bytes());
			m.extend_from_slice(path);
			if let Some(n) = name {
				m.extend_from_slice(b": ");
				m.extend_from_slice(n);
			}
			m.extend_from_slice(format!(": {sname}: {} (os error {})\n", explain(st), xs::last_os_error()).as_bytes());
		}
		eput(&m);
	}

	/// One framed cell: text (optionally colored), then padding to width.
	fn put_cell(&mut self, text: &[u8], width: usize, ansi: Option<&[u8]>) {
		let color = ansi.filter(|_| self.o.use_color && self.o.fmt == Fmt::Table);
		if let Some(a) = color {
			self.put(a);
		}
		self.put(text);
		if color.is_some() {
			self.put(ANSI_RESET);
		}
		for _ in utf8_count(text)..width {
			self.put(b" ");
		}
	}

	fn table_border(&mut self) {
		let corner: &[u8] = if self.o.fmt == Fmt::Table { b"+" } else { b"|" };
		let mut line = corner.to_vec();
		for col in 0..4 {
			if !self.present[col] {
				continue;
			}
			let w = if self.width[col] != 0 { self.width[col] } else { COL_LABEL[col].len() };
			line.extend(std::iter::repeat(b'-').take(w + 2));
			line.extend_from_slice(corner);
		}
		line.push(b'\n');
		self.put(&line);
	}

	fn framed_row(&mut self, cells: &[Vec<u8>; 4]) {
		for col in 0..4 {
			if !self.present[col] {
				continue;
			}
			self.put(b"| ");
			let ansi = match col {
				COL_NAME => Some(ANSI_NAME),
				COL_VALUE => Some(ANSI_VALUE),
				_ => None,
			};
			self.put_cell(&cells[col], self.width[col], ansi);
			self.put(b" ");
		}
		self.put(b"|\n");
	}

	fn header_row(&mut self) {
		let cells: [Vec<u8>; 4] = std::array::from_fn(|col| if self.present[col] { fit_cell(COL_LABEL[col].as_bytes(), self.width[col], false) } else { Vec::new() });
		if self.o.fmt == Fmt::Table {
			self.table_border();
		}
		self.framed_row(&cells);
		self.table_border();
	}

	/// Prints a displayed value in TSV form, cut to max_width characters with
	/// an ellipsis and the raw byte count when it does not fit.
	fn print_value_tsv(&mut self, disp: &[u8], raw_len: usize) {
		let shown = if self.o.max_width > 0 { utf8_prefix_bytes(disp, self.o.max_width) } else { disp.len() };
		if self.o.use_color {
			self.put(ANSI_VALUE);
		}
		self.put(&disp[..shown]);
		if self.o.use_color {
			self.put(ANSI_RESET);
		}
		if shown < disp.len() {
			self.put(ELLIPSIS);
			self.put(format!("({raw_len} bytes)").as_bytes());
		}
	}

	fn emit_entry(&mut self, path: &[u8], name: &[u8]) {
		let o = self.o;
		let mut raw_len = 0;
		let mut vd: (&str, Vec<u8>) = ("hex", Vec::new());
		if o.values {
			match xs::get(path, name, &o.xs()) {
				Ok(v) => {
					raw_len = v.len();
					vd = render_value(o, &v);
				}
				Err(e) => {
					self.warn_path(path, Some(name), status(e));
					return;
				}
			}
		}
		let mut line = Vec::new();
		if o.json {
			if !self.json_first {
				line.push(b',');
			}
			self.json_first = false;
			// Value listings never get here: json_file writes them per file.
			if !o.recurse {
				json_string(&mut line, name);
			} else {
				line.push(b'{');
				json_field_utf8_or_pb(&mut line, "path", path);
				line.push(b',');
				json_field_utf8_or_pb(&mut line, "name", name);
				line.push(b'}');
			}
			self.put(&line);
		} else if o.fmt == Fmt::Tsv {
			if o.recurse {
				line.extend_from_slice(path);
				line.push(b'\t');
			}
			if o.use_color {
				line.extend_from_slice(ANSI_NAME);
			}
			line.extend_from_slice(name);
			if o.use_color {
				line.extend_from_slice(ANSI_RESET);
			}
			self.put(&line);
			if o.values {
				if self.present[COL_TYPE] {
					self.put(format!("\t{}", vd.0).as_bytes());
				}
				self.put(b"\t");
				self.print_value_tsv(&vd.1, raw_len);
			}
			self.put(b"\n");
		} else {
			// Names go through printable-binary in the delimited formats so no
			// delimiter (| , tabs, control chars) can appear in them.
			let nb = pb::encode_preserving_spaces(name);
			if o.fmt == Fmt::Csv {
				if o.recurse {
					csv_field(&mut line, path);
					line.push(b',');
				}
				csv_field(&mut line, &nb);
				if o.values {
					line.push(b',');
					csv_field(&mut line, &vd.1);
				}
				line.push(b'\n');
				self.put(&line);
			} else {
				let bar: &[u8] = if o.fmt == Fmt::Table { "\u{2223}".as_bytes() } else { b"\\|" };
				let mut cells: [Vec<u8>; 4] = Default::default();
				if self.present[COL_PATH] {
					cells[COL_PATH] = escape_bars(&fit_cell(path, self.width[COL_PATH], true), bar);
				}
				cells[COL_NAME] = escape_bars(&fit_cell(&nb, self.width[COL_NAME], false), bar);
				if self.present[COL_TYPE] {
					cells[COL_TYPE] = escape_bars(&fit_cell(vd.0.as_bytes(), self.width[COL_TYPE], false), bar);
				}
				if self.present[COL_VALUE] {
					cells[COL_VALUE] = escape_bars(&fit_cell(&vd.1, self.width[COL_VALUE], false), bar);
				}
				self.framed_row(&cells);
			}
		}
	}

	/// JSON listing with values: one object per file on its own line, the
	/// format `load` reads back. UTF-8 names go under "xattrs", others (only
	/// possible with --raw) under "xattrs_pb"; values are always
	/// printable-binary. A file with no readable attributes produces no line.
	fn json_file(&mut self, path: &[u8], names: &[Vec<u8>]) {
		let mut line = Vec::new();
		let mut opened = false;
		for utf8_pass in [true, false] {
			let mut section_open = false;
			for name in names {
				if xs::is_utf8(name) != utf8_pass {
					continue;
				}
				let v = match xs::get(path, name, &self.o.xs()) {
					Ok(v) => v,
					Err(e) => {
						self.warn_path(path, Some(name), status(e));
						continue;
					}
				};
				if !opened {
					line.push(b'{');
					json_field_utf8_or_pb(&mut line, "path", path);
					opened = true;
				}
				if !section_open {
					line.extend_from_slice(if utf8_pass { b",\"xattrs\":{" } else { b",\"xattrs_pb\":{" });
					section_open = true;
				} else {
					line.push(b',');
				}
				if utf8_pass {
					json_string(&mut line, name);
				} else {
					json_string(&mut line, &pb::encode_preserving_spaces(name));
				}
				line.push(b':');
				json_string(&mut line, &pb::encode_preserving_spaces(&v));
			}
			if section_open {
				line.push(b'}');
			}
		}
		if opened {
			line.extend_from_slice(b"}\n");
			self.put(&line);
		}
	}

	fn list_one(&mut self, path: &[u8]) -> Result<(), Error> {
		let names = xs::list(path, &self.o.xs())?;
		if self.o.json && self.o.values {
			self.json_file(path, &names);
			return Ok(());
		}
		for n in &names {
			self.emit_entry(path, n);
		}
		Ok(())
	}

	fn walk_visit(&mut self, v: &walk::Visit) {
		if v.status != Status::Ok {
			self.warn_path(v.path, None, v.status.code());
			return;
		}
		match self.list_one(v.path) {
			Ok(()) => {}
			// An entry that cannot be found any more has nothing to list: a
			// dangling symlink, or a file deleted between reading its directory
			// and now. That is the tree's state, not an error in the walk, so it
			// is skipped without noise unless --debug. The root is exempt.
			Err(Error::NotFound) if v.depth > 0 => {
				if self.o.debug {
					let symlink = v.kind == walk::Kind::Symlink;
					let mut m = Vec::new();
					if self.o.json {
						m.extend_from_slice(format!("{{\"debug\":\"{}\",", if symlink { "dangling_symlink" } else { "vanished" }).as_bytes());
						json_field_utf8_or_pb(&mut m, "path", v.path);
						m.extend_from_slice(b"}\n");
					} else {
						m.extend_from_slice(format!("{PROG}: debug: ").as_bytes());
						m.extend_from_slice(v.path);
						m.extend_from_slice(if symlink { b": dangling symlink, skipped\n" } else { b": vanished during the walk, skipped\n" });
					}
					eput(&m);
				}
			}
			Err(e) => self.warn_path(v.path, None, status(e)),
		}
	}
}

fn resolve_color(o: &Cli) -> bool {
	if o.json || o.color == 0 {
		return false;
	}
	if o.color == 1 {
		return true;
	}
	if std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty()) {
		return false;
	}
	io::stdout().is_terminal() && enable_vt()
}

/// Windows consoles interpret ANSI only after opting in.
#[cfg(windows)]
fn enable_vt() -> bool {
	type Handle = *mut std::ffi::c_void;
	#[link(name = "kernel32")]
	extern "system" {
		fn GetStdHandle(n: u32) -> Handle;
		fn GetConsoleMode(h: Handle, mode: *mut u32) -> i32;
		fn SetConsoleMode(h: Handle, mode: u32) -> i32;
	}
	const STD_OUTPUT_HANDLE: u32 = -11i32 as u32;
	const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
	// SAFETY: plain console API calls with a valid out-pointer.
	unsafe {
		let h = GetStdHandle(STD_OUTPUT_HANDLE);
		let mut mode = 0u32;
		if h as usize == usize::MAX || GetConsoleMode(h, &mut mode) == 0 {
			return false;
		}
		SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0
	}
}

#[cfg(not(windows))]
fn enable_vt() -> bool {
	true
}

fn cmd_lst(o: &mut Cli, path: &[u8]) -> i32 {
	o.use_color = resolve_color(o);
	let o = &*o;
	let present = [o.recurse, true, o.values && o.utf8 && o.fmt != Fmt::Csv, o.values];
	let mut width = [0usize; 4];
	let mut k = 0;
	for col in 0..4 {
		if present[col] {
			width[col] = o.cols.get(k).copied().unwrap_or(COL_DEFAULT_WIDTH[col]);
			k += 1;
		}
	}
	let mut c = Lst { o, out: BufWriter::new(text_stdout()), json_first: true, failures: 0, present, width };
	let framed = !o.json && matches!(o.fmt, Fmt::Table | Fmt::Md);
	// Names-only listings stay a JSON array.
	let json_array = o.json && !o.values;
	if json_array {
		c.put(b"[");
	} else if framed {
		c.header_row();
	} else if o.fmt == Fmt::Csv {
		let labels: Vec<&str> = (0..4).filter(|&col| present[col]).map(|col| COL_LABEL[col]).collect();
		c.put(format!("{}\n", labels.join(",")).as_bytes());
	}
	let result = if o.recurse {
		let opts = walk::Options {
			order: if o.depth_first { walk::Order::DepthFirst } else { walk::Order::BreadthFirst },
			max_depth: usize::try_from(o.max_depth).ok(),
		};
		walk::walk(&walk::FsLister, path, opts, |v| {
			c.walk_visit(v);
			true
		})
	} else {
		c.list_one(path)
	};
	if json_array {
		c.put(b"]\n");
	} else if framed && o.fmt == Fmt::Table {
		c.table_border();
	}
	let flushed = c.out.flush().is_ok();
	if let Err(e) = result {
		report(o, "lst", Some(path), None, status(e));
		return exit_for(status(e));
	}
	if !flushed {
		return EXIT_ERROR;
	}
	if c.failures > 0 {
		EXIT_ERROR
	} else {
		EXIT_OK
	}
}

fn cmd_limits(o: &Cli, path: &[u8]) -> i32 {
	let n = xs::limits(path);
	let line = if o.json { format!("{{\"max_value_bytes\":{n}}}") } else { n.to_string() };
	println_out(line.as_bytes())
}

// ---- load: restore a `dump --json` stream ----------------------------------

struct Load<'a> {
	o: &'a Cli,
	line: u64,
	/// Resolved target of the current line.
	path: Vec<u8>,
	/// The line's path was refused or unusable.
	skip: bool,
	failures: usize,
}

impl Load<'_> {
	/// One load problem, with its line number. `message` overrides the
	/// status's generic explanation. Never silenced by --quiet.
	fn report(&mut self, path: Option<&[u8]>, name: Option<&[u8]>, st: i32, message: Option<&str>) {
		let sname = xs::status_name(st);
		let msg = message.unwrap_or_else(|| explain(st));
		self.failures += 1;
		let mut m = Vec::new();
		if self.o.json {
			m.extend_from_slice(b"{\"status\":");
			json_string(&mut m, sname.as_bytes());
			m.extend_from_slice(format!(",\"op\":\"load\",\"line\":{}", self.line).as_bytes());
			if let Some(p) = path {
				m.push(b',');
				json_field_utf8_or_pb(&mut m, "path", p);
			}
			if let Some(n) = name {
				m.push(b',');
				json_field_utf8_or_pb(&mut m, "name", n);
			}
			m.extend_from_slice(b",\"message\":");
			json_string(&mut m, msg.as_bytes());
			m.extend_from_slice(b"}\n");
		} else {
			m.extend_from_slice(format!("{PROG}: load: line {}: ", self.line).as_bytes());
			if let Some(p) = path {
				m.extend_from_slice(p);
				m.extend_from_slice(b": ");
			}
			if let Some(n) = name {
				m.extend_from_slice(n);
				m.extend_from_slice(b": ");
			}
			m.extend_from_slice(format!("{sname}: {msg}\n").as_bytes());
		}
		eput(&m);
	}

	/// Joins --root and a relative dump path; absolute paths (allowed only
	/// with --allow-unsafe-paths) are used as written.
	fn set_path(&mut self, p: &[u8]) {
		self.path = match &self.o.root {
			Some(root) if !dump::is_absolute_path(p) => [root.as_slice(), b"/", p].concat(),
			_ => p.to_vec(),
		};
	}

	/// The path arrives first and is checked against the restore guard, then
	/// each attribute is decoded and written. Problems are reported and
	/// counted; the line's other attributes are still written.
	fn field(&mut self, field: dump::Field, key: &[u8], value: &[u8]) {
		match field {
			dump::Field::Path | dump::Field::PathPb => {
				let p = if field == dump::Field::PathPb { pb::decode(value) } else { value.to_vec() };
				self.skip = true;
				if !self.o.allow_unsafe_paths && !dump::is_contained_relative_path(&p) {
					self.report(Some(&p), None, Status::InvalidPath.code(), Some("absolute path or .. component refused (--allow-unsafe-paths permits it)"));
				} else {
					self.set_path(&p);
					self.skip = false;
				}
			}
			dump::Field::Xattr | dump::Field::XattrPb => {
				if self.skip {
					return;
				}
				// An empty name under xattrs_pb decodes to no name at all, which
				// the reports then omit, as the C CLI's do.
				let name: Option<Vec<u8>> = match field {
					dump::Field::XattrPb if key.is_empty() => None,
					dump::Field::XattrPb => Some(pb::decode(key)),
					_ => Some(key.to_vec()),
				};
				let n = name.as_deref().unwrap_or(b"");
				let val = pb::decode(value);
				warn_portability(self.o, val.len());
				if let Err(e) = xs::set(&self.path, n, &val, &self.o.xs()) {
					let path = self.path.clone();
					self.report(Some(&path), name.as_deref(), status(e), None);
				}
			}
		}
	}
}

/// Restores attributes from a `dump --json` stream, line by line. Bad lines
/// and refused paths are reported with their line number and skipped; the
/// exit code is 1 if anything was skipped.
fn cmd_load(o: &Cli, file: Option<&[u8]>) -> i32 {
	let mut input: Box<dyn io::BufRead> = match file {
		Some(f) if f != b"-" && f != b"@stdin" => {
			let opened = xs::path_from_bytes(f).ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput)).and_then(std::fs::File::open);
			match opened {
				Ok(h) => Box::new(io::BufReader::new(h)),
				Err(e) => {
					let st = match e.kind() {
						io::ErrorKind::NotFound => Status::NotFound,
						io::ErrorKind::PermissionDenied => Status::Permission,
						_ if is_enotdir(&e) => Status::NotFound,
						_ => Status::Io,
					}
					.code();
					report(o, "load", Some(f), None, st);
					return exit_for(st);
				}
			}
		}
		_ => Box::new(io::BufReader::new(io::stdin().lock())),
	};
	let mut c = Load { o, line: 0, path: Vec::new(), skip: true, failures: 0 };
	let mut buf = Vec::new();
	loop {
		buf.clear();
		match input.read_until(b'\n', &mut buf) {
			Ok(0) => break,
			Ok(_) => {}
			Err(_) => {
				c.report(None, None, Status::Io.code(), Some("reading the dump failed"));
				break;
			}
		}
		if buf.last() == Some(&b'\n') {
			buf.pop();
		}
		if buf.last() == Some(&b'\r') {
			buf.pop();
		}
		c.line += 1;
		if buf.iter().all(|&b| b == b' ' || b == b'\t') {
			continue;
		}
		c.skip = true;
		let mut fields: Vec<(dump::Field, Vec<u8>, Vec<u8>)> = Vec::new();
		match dump::parse_line(&buf, |f, k, v| {
			fields.push((f, k.to_vec(), v.to_vec()));
			true
		}) {
			Ok(()) => {
				for (f, k, v) in fields {
					c.field(f, &k, &v);
				}
			}
			Err(dump::Malformed) => c.report(
				None,
				None,
				Status::InvalidArgument.code(),
				Some("not a dump line: expected one JSON object with \"path\" or \"path_pb\" and optional \"xattrs\" / \"xattrs_pb\""),
			),
		}
	}
	if c.failures > 0 {
		EXIT_ERROR
	} else {
		EXIT_OK
	}
}

#[cfg(unix)]
fn is_enotdir(e: &io::Error) -> bool {
	// ENOTDIR is 20 on Linux and macOS.
	e.raw_os_error() == Some(20)
}

#[cfg(windows)]
fn is_enotdir(_: &io::Error) -> bool {
	false
}

/// Command-line argument as encoded bytes (raw on POSIX, WTF-8 on Windows).
fn arg_bytes(a: &OsString) -> Vec<u8> {
	a.as_encoded_bytes().to_vec()
}

/// A plain decimal number: one or more ASCII digits and nothing else, with
/// no overflow (no whitespace, no sign, as the C CLI's parse_digits).
fn parse_digits(s: &[u8]) -> Option<u64> {
	if s.is_empty() || !s.iter().all(u8::is_ascii_digit) {
		return None;
	}
	s.iter().try_fold(0u64, |v, &c| v.checked_mul(10)?.checked_add(u64::from(c - b'0')))
}

fn parse_u64(s: Option<&[u8]>) -> Option<u64> {
	parse_digits(s?)
}

fn usage_err() -> i32 {
	eput(USAGE.as_bytes());
	EXIT_USAGE
}

/// The option's inline `=value`, or the next argument.
fn opt_value(a: &[u8], args: &[Vec<u8>], i: &mut usize) -> Option<Vec<u8>> {
	if let Some(eq) = a.iter().position(|&c| c == b'=') {
		return Some(a[eq + 1..].to_vec());
	}
	if *i + 1 < args.len() {
		*i += 1;
		return Some(args[*i].clone());
	}
	None
}

/// Windows switch spelling: /name or /x, with an optional value after : or =,
/// is the same as --name or -x (value after =); /? is -h. A name holding a
/// path separator is a path, so /tmp/f stays positional; a one-component path
/// such as /json needs -- or a backslash. None for anything else.
fn slash_switch(a: &[u8]) -> Option<Vec<u8>> {
	let rest = a.strip_prefix(b"/").filter(|r| !r.is_empty())?;
	let rest: &[u8] = if rest == b"?" { b"h" } else { rest };
	let n = rest.iter().position(|&c| c == b':' || c == b'=').unwrap_or(rest.len());
	let name = &rest[..n];
	if name.is_empty() || name.iter().any(|&c| c == b'/' || c == b'\\') {
		return None;
	}
	let mut s = if n == 1 { b"-".to_vec() } else { b"--".to_vec() };
	s.extend_from_slice(name);
	if n < rest.len() {
		s.push(b'=');
		s.extend_from_slice(&rest[n + 1..]);
	}
	Some(s)
}

fn run() -> i32 {
	let args: Vec<Vec<u8>> = std::env::args_os().skip(1).map(|a| arg_bytes(&a)).collect();
	let mut o = Cli {
		limit: xs::DEFAULT_MAX_VALUE_LEN as u64,
		nofollow: false,
		raw: false,
		json: false,
		fmt: Fmt::Tsv,
		utf8: false,
		cols: Vec::new(),
		quiet: false,
		recurse: false,
		max_depth: -1,
		depth_first: false,
		values: false,
		debug: std::env::var_os("DEBUG").is_some_and(|v| !v.is_empty() && v != "0"),
		hex: false,
		max_width: 0,
		color: -1,
		use_color: false,
		root: None,
		allow_unsafe_paths: false,
	};
	let mut cols_given = false;
	let mut pos: Vec<Vec<u8>> = Vec::new();
	let mut only_positional = false;
	let mut i = 0;
	while i < args.len() {
		let dash = if !only_positional && windows() { slash_switch(&args[i]) } else { None };
		let a = dash.as_deref().unwrap_or(args[i].as_slice());
		if !only_positional && a.len() > 1 && a[0] == b'-' {
			match a {
				b"--" => only_positional = true,
				b"--help" | b"-h" => {
					let _ = text_stdout().write_all(USAGE.as_bytes());
					return EXIT_OK;
				}
				b"--version" => return println_out(format!("{PROG} {}", xs::VERSION).as_bytes()),
				b"--about" => {
					return println_out(format!("{PROG} {}: cross-platform binary-safe file attributes (xattrs / NTFS streams), Rust implementation, for {}", xs::VERSION, xs::PLATFORM).as_bytes());
				}
				b"--nofollow" => o.nofollow = true,
				b"--raw" => o.raw = true,
				b"--json" => o.json = true,
				b"--quiet" => o.quiet = true,
				b"-r" | b"--recurse" => o.recurse = true,
				b"--depth-first" => o.depth_first = true,
				b"--values" => o.values = true,
				b"--debug" => o.debug = true,
				b"--hex" => o.hex = true,
				b"--utf8" => o.utf8 = true,
				b"--tsv" => o.fmt = Fmt::Tsv,
				b"--csv" => o.fmt = Fmt::Csv,
				b"--table" => o.fmt = Fmt::Table,
				b"--md" | b"--markdown" => o.fmt = Fmt::Md,
				b"--allow-unsafe-paths" => o.allow_unsafe_paths = true,
				b"--color" => o.color = 1,
				b"--no-color" | b"--no-ansi" | b"--simple" => o.color = 0,
				_ if a == b"--cols" || a == b"--columns" || a.starts_with(b"--cols=") || a.starts_with(b"--columns=") => {
					let spec = match opt_value(a, &args, &mut i) {
						Some(s) if !s.is_empty() => s,
						_ => return usage_err(),
					};
					o.cols.clear();
					for item in spec.split(|&c| c == b',') {
						match parse_digits(item).and_then(|w| usize::try_from(w).ok()) {
							Some(w) if o.cols.len() < MAX_COLS => o.cols.push(w),
							_ => {
								eput(format!("{PROG}: --cols needs up to {MAX_COLS} comma-separated non-negative integers\n").as_bytes());
								return usage_err();
							}
						}
					}
					cols_given = true;
				}
				_ if a == b"-w" || a == b"--max-width" || a.starts_with(b"-w=") || a.starts_with(b"--max-width=") => {
					match parse_u64(opt_value(a, &args, &mut i).as_deref()) {
						Some(w) => o.max_width = w as usize,
						None => {
							eput(format!("{PROG}: --max-width needs a non-negative integer\n").as_bytes());
							return usage_err();
						}
					}
				}
				_ if a == b"--root" || a.starts_with(b"--root=") => match opt_value(a, &args, &mut i) {
					Some(d) if !d.is_empty() => o.root = Some(d),
					_ => {
						eput(format!("{PROG}: --root needs a directory\n").as_bytes());
						return usage_err();
					}
				},
				_ if a == b"-d" || a == b"--depth" || a.starts_with(b"-d=") || a.starts_with(b"--depth=") => {
					match parse_u64(opt_value(a, &args, &mut i).as_deref()).and_then(|d| i64::try_from(d).ok()) {
						Some(d) => {
							o.max_depth = d;
							o.recurse = true;
						}
						None => {
							eput(format!("{PROG}: --depth needs a non-negative integer\n").as_bytes());
							return usage_err();
						}
					}
				}
				_ if a == b"--limit" || a.starts_with(b"--limit=") => {
					match parse_u64(opt_value(a, &args, &mut i).as_deref()) {
						Some(n) => o.limit = n,
						None => {
							eput(format!("{PROG}: --limit needs a non-negative integer\n").as_bytes());
							return usage_err();
						}
					}
				}
				_ => {
					let mut m = format!("{PROG}: unknown option '").into_bytes();
					m.extend_from_slice(&args[i]);
					m.extend_from_slice(b"'\n");
					eput(&m);
					return usage_err();
				}
			}
			i += 1;
			continue;
		}
		if pos.len() == 3 {
			return usage_err();
		}
		pos.push(a.to_vec());
		i += 1;
	}

	// Explicit widths mean a framed table unless Markdown was asked for.
	if cols_given && o.fmt != Fmt::Md && o.fmt != Fmt::Csv {
		o.fmt = Fmt::Table;
	}
	let Some(cmd) = pos.first() else { return usage_err() };
	let nargs = pos.len() - 1;
	match cmd.as_slice() {
		b"put" | b"set" if nargs == 2 => cmd_put(&o, &pos[1], &pos[2]),
		b"get" if nargs == 2 => cmd_get(&o, &pos[1], &pos[2]),
		b"len" if nargs == 2 => cmd_len(&o, &pos[1], &pos[2]),
		b"del" if nargs == 2 => cmd_del(&o, &pos[1], &pos[2]),
		b"put" | b"set" | b"get" | b"len" | b"del" => usage_err(),
		b"lst" | b"list" | b"dump" | b"dmp" if nargs == 1 => {
			if cmd.as_slice() == b"dump" || cmd.as_slice() == b"dmp" {
				o.values = true;
			}
			let path = pos[1].clone();
			cmd_lst(&mut o, &path)
		}
		b"lst" | b"list" | b"dump" | b"dmp" => usage_err(),
		b"load" if nargs <= 1 => cmd_load(&o, pos.get(1).map(Vec::as_slice)),
		b"limits" | b"lim" if nargs <= 1 => cmd_limits(&o, pos.get(1).map_or(b".".as_slice(), Vec::as_slice)),
		b"load" | b"limits" | b"lim" => usage_err(),
		_ => {
			let mut m = format!("{PROG}: unknown command '").into_bytes();
			m.extend_from_slice(cmd);
			m.extend_from_slice(b"'\n");
			eput(&m);
			usage_err()
		}
	}
}

/// A closed pipe ends the program quietly with SIGPIPE, as it does for the C
/// CLI, instead of surfacing as a write error.
#[cfg(unix)]
fn default_sigpipe() {
	extern "C" {
		fn signal(sig: i32, handler: usize) -> usize;
	}
	const SIGPIPE: i32 = 13;
	// SAFETY: restoring the default disposition (SIG_DFL = 0) at startup.
	unsafe { signal(SIGPIPE, 0) };
}

#[cfg(not(unix))]
fn default_sigpipe() {}

fn main() {
	// A debug build says so, so nobody benchmarks or ships one by mistake.
	// MUTE_DEBUG_STATUS (any non-empty value) silences it.
	if cfg!(debug_assertions) && std::env::var_os("MUTE_DEBUG_STATUS").map_or(true, |v| v.is_empty()) {
		eput(b"\x1b[33mDEBUG BUILD!\x1b[0m\n");
	}
	default_sigpipe();
	std::process::exit(run());
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn parse_u64_accepts_whole_non_negative_numbers_only() {
		assert_eq!(parse_u64(Some(b"0")), Some(0));
		assert_eq!(parse_u64(Some(b"65536")), Some(65536));
		assert_eq!(parse_u64(Some(b"18446744073709551615")), Some(u64::MAX));
		for bad in [&b""[..], b"-1", b"+1", b" 1", b"1 ", b"1x", b"x", b"18446744073709551616"] {
			assert_eq!(parse_u64(Some(bad)), None, "{}", String::from_utf8_lossy(bad));
		}
		assert_eq!(parse_u64(None), None);
	}

	#[test]
	fn slash_switches_map_to_dash_spellings_and_paths_stay_positional() {
		let s = |a: &str| slash_switch(a.as_bytes()).map(|v| String::from_utf8(v).unwrap());
		assert_eq!(s("/json").as_deref(), Some("--json"));
		assert_eq!(s("/r").as_deref(), Some("-r"));
		assert_eq!(s("/?").as_deref(), Some("-h"));
		assert_eq!(s("/w:5").as_deref(), Some("-w=5"));
		assert_eq!(s("/cols=3,4").as_deref(), Some("--cols=3,4"));
		assert_eq!(s("/root:C:\\dir").as_deref(), Some("--root=C:\\dir"));
		for path in ["/", "/tmp/f", "/a\\b", "/:x", "json", "--json", ""] {
			assert_eq!(s(path), None, "{path}");
		}
	}

	/// Text must reach the terminal only through the line-ending translation,
	/// so the streams are opened in exactly three places (plus the terminal
	/// check); anything new has to choose text or raw on purpose.
	#[test]
	fn standard_streams_are_opened_only_by_the_text_and_raw_helpers() {
		let src = include_str!("main.rs");
		let opened = |pat: &str| src.matches(pat).count();
		// concat! keeps the patterns themselves out of the count.
		assert_eq!(opened(concat!("io::", "stdout()")), 3, "stdout opened outside text_stdout, raw_stdout and the terminal check");
		assert_eq!(opened(concat!("io::", "stderr()")), 1, "stderr opened outside text_stderr");
		assert_eq!(opened(concat!("print", "!(")) + opened(concat!("println", "!(")) + opened(concat!("eprint", "ln!(")), 0);
	}

	#[test]
	fn cell_fitting_truncates_by_code_point_keeping_start_or_end() {
		assert_eq!(fit_cell(b"abcdef", 4, false), "abc\u{2026}".as_bytes());
		assert_eq!(fit_cell(b"abcdef", 4, true), "\u{2026}def".as_bytes());
		assert_eq!(fit_cell("ééééé".as_bytes(), 3, false), "éé\u{2026}".as_bytes());
		assert_eq!(fit_cell(b"abc", 0, false), b"abc");
		assert_eq!(fit_cell(b"abc", 1, true), "\u{2026}".as_bytes());
	}
}
