//! Independent Rust consumer of the C ABI, linked statically against
//! libxattr_stream.a with plain rustc (no cargo, no crates).
//! Creates its own fixture file in the current directory and removes it.
use std::ffi::{c_void, CStr};
use std::os::raw::{c_char, c_int};

#[repr(C)]
struct XsOptions {
	flags: u32,
	max_value_len: u64,
}

#[repr(C)]
struct XsBuffer {
	data: *mut u8,
	len: usize,
	cap: usize,
}

const XS_OK: c_int = 0;
const XS_MISSING: c_int = 1;
const XS_UNSUPPORTED: c_int = 2;
const XS_INVALID_NAME: c_int = 7;

#[link(name = "xattr_stream", kind = "static")]
extern "C" {
	fn xs_set(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, value: *const c_void, value_len: usize, opts: *const XsOptions) -> c_int;
	fn xs_size(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, opts: *const XsOptions, out_len: *mut u64) -> c_int;
	fn xs_get(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, opts: *const XsOptions, out: *mut XsBuffer) -> c_int;
	fn xs_remove(path: *const c_char, path_len: usize, name: *const c_char, name_len: usize, opts: *const XsOptions) -> c_int;
	fn xs_list(path: *const c_char, path_len: usize, opts: *const XsOptions, out: *mut XsBuffer, out_count: *mut usize) -> c_int;
	fn xs_buffer_free(buf: *mut XsBuffer);
	fn xs_status_name(status: c_int) -> *const c_char;
	fn xs_version() -> *const c_char;
	fn xs_target() -> *const c_char;
}

fn p(s: &str) -> *const c_char {
	s.as_ptr() as *const c_char
}

fn main() {
	let path = "xs_consumer_rs.tmp";
	std::fs::write(path, b"").expect("create fixture");
	let all: Vec<u8> = (0..=255u8).collect();
	let mut failures = 0;
	macro_rules! check {
		($cond:expr, $msg:expr) => {
			if !$cond {
				failures += 1;
				eprintln!("FAIL: {}", $msg);
			}
		};
	}

	unsafe {
		let st = xs_set(p(path), path.len(), p("probe"), 5, all.as_ptr() as *const c_void, all.len(), std::ptr::null());
		if st == XS_UNSUPPORTED {
			eprintln!("SKIP: filesystem does not support attributes");
			let _ = std::fs::remove_file(path);
			return;
		}
		check!(st == XS_OK, "xs_set");

		let mut len: u64 = 0;
		check!(xs_size(p(path), path.len(), p("probe"), 5, std::ptr::null(), &mut len) == XS_OK && len == 256, "xs_size == 256");

		let mut buf = XsBuffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
		check!(xs_get(p(path), path.len(), p("probe"), 5, std::ptr::null(), &mut buf) == XS_OK, "xs_get");
		let got = std::slice::from_raw_parts(buf.data, buf.len).to_vec();
		xs_buffer_free(&mut buf);
		check!(got == all, "round trip bytes");
		check!(buf.data.is_null() && buf.len == 0, "xs_buffer_free zeroes");

		let tight = XsOptions { flags: 0, max_value_len: 8 };
		let mut b2 = XsBuffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
		check!(xs_get(p(path), path.len(), p("probe"), 5, &tight, &mut b2) == 5, "max_value_len bounds get (XS_TOO_LARGE)");

		let mut names = XsBuffer { data: std::ptr::null_mut(), len: 0, cap: 0 };
		let mut count: usize = 0;
		check!(xs_list(p(path), path.len(), std::ptr::null(), &mut names, &mut count) == XS_OK && count == 1, "xs_list count 1");
		let packed = std::slice::from_raw_parts(names.data, names.len).to_vec();
		xs_buffer_free(&mut names);
		check!(packed == b"probe\0", "xs_list packing");

		check!(xs_set(p(path), path.len(), p("a:b"), 3, p("v") as *const c_void, 1, std::ptr::null()) == XS_INVALID_NAME, "invalid name");
		check!(CStr::from_ptr(xs_status_name(XS_MISSING)).to_str().unwrap() == "XS_MISSING", "status name");
		check!(xs_remove(p(path), path.len(), p("probe"), 5, std::ptr::null()) == XS_OK, "xs_remove");
		check!(xs_size(p(path), path.len(), p("probe"), 5, std::ptr::null(), &mut len) == XS_MISSING, "size after remove");

		if failures == 0 {
			println!(
				"Rust consumer: ok ({}, {})",
				CStr::from_ptr(xs_version()).to_str().unwrap(),
				CStr::from_ptr(xs_target()).to_str().unwrap()
			);
		}
	}
	let _ = std::fs::remove_file(path);
	std::process::exit(failures);
}
