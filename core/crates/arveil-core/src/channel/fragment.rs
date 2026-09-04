//! Fragmentation of frames into Noise payloads.
//!
//! Wire format of one fragment: `flags(1 byte) || data`. `flags` bit 0 is
//! set on the last fragment of a frame. Fragments of one frame are sent
//! back to back on the same channel; interleaving is not allowed, which
//! keeps the reassembler a single bounded buffer.

use super::noise::MAX_NOISE_PAYLOAD;

pub const FLAG_LAST: u8 = 0b0000_0001;
/// Data bytes per fragment.
pub const FRAGMENT_DATA: usize = MAX_NOISE_PAYLOAD - 1;

#[derive(Debug, thiserror::Error)]
pub enum FragmentError {
    #[error("fragment: empty message")]
    Empty,
    #[error("fragment: unknown flags {0:#04x}")]
    UnknownFlags(u8),
    #[error("fragment: reassembled frame would exceed {limit} bytes")]
    TooLarge { limit: usize },
}

/// Split encoded frame bytes into fragments. Always yields at least one.
pub fn fragments(bytes: &[u8]) -> impl Iterator<Item = Vec<u8>> + '_ {
    let chunks: Vec<&[u8]> = if bytes.is_empty() {
        vec![&[][..]]
    } else {
        bytes.chunks(FRAGMENT_DATA).collect()
    };
    let last = chunks.len() - 1;
    chunks.into_iter().enumerate().map(move |(i, chunk)| {
        let mut out = Vec::with_capacity(chunk.len() + 1);
        out.push(if i == last { FLAG_LAST } else { 0 });
        out.extend_from_slice(chunk);
        out
    })
}

/// Bounded reassembly buffer for one channel.
pub struct Reassembler {
    limit: usize,
    buffer: Vec<u8>,
}

impl Reassembler {
    pub fn new(limit: usize) -> Self {
        Self {
            limit,
            buffer: Vec::new(),
        }
    }

    /// Push one fragment. Returns the complete frame bytes on the last one.
    pub fn push(&mut self, fragment: &[u8]) -> Result<Option<Vec<u8>>, FragmentError> {
        let (&flags, data) = fragment.split_first().ok_or(FragmentError::Empty)?;
        if flags & !FLAG_LAST != 0 {
            return Err(FragmentError::UnknownFlags(flags));
        }
        if self.buffer.len() + data.len() > self.limit {
            self.buffer.clear();
            return Err(FragmentError::TooLarge { limit: self.limit });
        }
        self.buffer.extend_from_slice(data);
        if flags & FLAG_LAST != 0 {
            Ok(Some(std::mem::take(&mut self.buffer)))
        } else {
            Ok(None)
        }
    }

    /// True while a frame is partially received.
    pub fn is_mid_frame(&self) -> bool {
        !self.buffer.is_empty()
    }
}
