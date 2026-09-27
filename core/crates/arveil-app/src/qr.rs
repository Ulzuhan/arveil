//! QR codes for the links of ADR-012, drawn and read in the core.
//!
//! Drawing is small and deterministic. Reading parses what a camera sees,
//! which anyone can put in front of it, so it happens here, in memory-safe
//! code with no network and no native library, and the result is only text
//! that [`crate::links::Card::parse`] still has to accept.

use qrcode::{EcLevel, QrCode};

/// A camera frame wider or taller than this is not a phone preview.
const MAX_FRAME_SIDE: u32 = 4096;

/// Dark and light modules, row by row, without the quiet zone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QrMatrix {
    pub width: u32,
    pub dark: Vec<bool>,
}

/// Encode text with error correction M (ADR-012 §1).
pub fn encode(text: &str) -> Option<QrMatrix> {
    let code = QrCode::with_error_correction_level(text.as_bytes(), EcLevel::M).ok()?;
    let width = u32::try_from(code.width()).ok()?;
    let dark = code
        .to_colors()
        .into_iter()
        .map(|c| c == qrcode::Color::Dark)
        .collect();
    Some(QrMatrix { width, dark })
}

/// Read every QR code in a greyscale frame (one byte of luminance per pixel,
/// rows `row_stride` bytes apart, as a camera's Y plane arrives). Codes that
/// do not decode as UTF-8 text are skipped.
pub fn decode(width: u32, height: u32, row_stride: u32, luma: &[u8]) -> Vec<String> {
    if width == 0
        || height == 0
        || width > MAX_FRAME_SIDE
        || height > MAX_FRAME_SIDE
        || row_stride < width
    {
        return Vec::new();
    }
    let (w, h, stride) = (width as usize, height as usize, row_stride as usize);
    if luma.len() < stride * (h - 1) + w {
        return Vec::new();
    }
    let mut image = rqrr::PreparedImage::prepare_from_greyscale(w, h, |x, y| luma[y * stride + x]);
    image
        .detect_grids()
        .into_iter()
        .filter_map(|grid| grid.decode().ok().map(|(_, text)| text))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Render a matrix as a camera would see it: scaled, with a quiet zone,
    /// inside a wider frame with padding at the end of every row.
    fn frame(m: &QrMatrix, scale: usize) -> (u32, u32, u32, Vec<u8>) {
        let side = (m.width as usize + 8) * scale;
        let (w, h, stride) = (side + 40, side + 20, side + 64);
        let mut luma = vec![255u8; stride * h];
        for y in 0..m.width as usize {
            for x in 0..m.width as usize {
                if m.dark[y * m.width as usize + x] {
                    for dy in 0..scale {
                        for dx in 0..scale {
                            let (px, py) = ((x + 4) * scale + dx + 10, (y + 4) * scale + dy + 5);
                            luma[py * stride + px] = 20;
                        }
                    }
                }
            }
        }
        (w as u32, h as u32, stride as u32, luma)
    }

    #[test]
    fn a_link_drawn_here_is_read_back_from_a_frame() {
        let link = format!("https://arveil.kaicorplabs.com/contact#{}", "A".repeat(520));
        let m = encode(&link).unwrap();
        assert_eq!(m.dark.len(), (m.width * m.width) as usize);
        let (w, h, stride, luma) = frame(&m, 4);
        assert_eq!(decode(w, h, stride, &luma), vec![link]);
    }

    #[test]
    fn a_frame_without_a_code_or_with_bad_geometry_reads_nothing() {
        assert!(decode(64, 64, 64, &vec![255; 64 * 64]).is_empty());
        assert!(decode(64, 64, 32, &vec![255; 64 * 64]).is_empty());
        assert!(decode(64, 64, 64, &[255; 10]).is_empty());
        assert!(decode(0, 64, 64, &[]).is_empty());
        assert!(decode(MAX_FRAME_SIDE + 1, 1, MAX_FRAME_SIDE + 1, &[]).is_empty());
    }

    #[test]
    fn the_same_text_always_draws_the_same_code() {
        assert_eq!(encode("arveil"), encode("arveil"));
    }
}
