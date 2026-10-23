//! OS adapters, one per supported OS, each implementing `crate::Adapter` as
//! `Native`, plus the encoded-bytes path conversions the walker needs.
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub(crate) use linux::*;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub(crate) use macos::*;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub(crate) use windows::*;

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
compile_error!("xattr_stream supports Linux, macOS and Windows only");

// Platform name (PF), <OS>-<ARCH>, for each of the six supported platforms.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
pub(crate) const PLATFORM: &str = "linux-amd64";
#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
pub(crate) const PLATFORM: &str = "linux-arm64";
#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
pub(crate) const PLATFORM: &str = "macos-amd64";
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
pub(crate) const PLATFORM: &str = "macos-arm64";
#[cfg(all(windows, target_arch = "x86_64"))]
pub(crate) const PLATFORM: &str = "mswin-amd64";
#[cfg(all(windows, target_arch = "aarch64"))]
pub(crate) const PLATFORM: &str = "mswin-arm64";
#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
compile_error!("xattr_stream supports amd64 and arm64 only");

#[cfg(unix)]
pub(crate) fn path_from_bytes(bytes: &[u8]) -> Option<std::path::PathBuf> {
	use std::os::unix::ffi::OsStrExt;
	Some(std::ffi::OsStr::from_bytes(bytes).into())
}

#[cfg(unix)]
pub(crate) fn bytes_from_os(s: &std::ffi::OsStr) -> Vec<u8> {
	use std::os::unix::ffi::OsStrExt;
	s.as_bytes().to_vec()
}
