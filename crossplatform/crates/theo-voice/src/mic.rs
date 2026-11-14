//! The microphone, and the audio it records.
//!
//! [`Recorder`] opens an input through cpal (WASAPI on Windows) on a thread of its own (a cpal stream can't move between
//! threads on every platform), keeps the samples as mono, and reports a live level for the pill's waveform. [`Recorder::stop`]
//! hands back [`Audio`]: 16 kHz mono PCM16, what every speech service takes, with a WAV writer ([`Audio::to_wav`]) and a
//! reader ([`Audio::from_wav`], for `dictationTest` and tests).
//!
//! Like the Mac's `DictationCapture`, it never asks for a permission: when Windows' microphone privacy switch is off, opening
//! the input fails and the words say where the switch is.

use anyhow::{anyhow, bail, Result};

/// What every speech service here takes.
pub const SAMPLE_RATE: u32 = 16_000;

/// The longest a recording is kept (a forgotten held chord shouldn't fill memory).
pub const MAXIMUM_SECONDS: u32 = 5 * 60;

/// Recorded audio: 16 kHz mono, 16-bit.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Audio {
    pub samples: Vec<i16>,
    pub sample_rate: u32,
}

impl Audio {
    pub fn from_samples(samples: Vec<i16>) -> Self {
        Self { samples, sample_rate: SAMPLE_RATE }
    }

    /// Mono float samples at any rate, converted to 16 kHz PCM16.
    pub fn from_float(samples: &[f32], sample_rate: u32) -> Self {
        let resampled = resample(samples, sample_rate, SAMPLE_RATE);
        Self::from_samples(resampled.iter().map(|sample| float_to_pcm16(*sample)).collect())
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub fn duration_seconds(&self) -> f64 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.samples.len() as f64 / self.sample_rate as f64
    }

    /// The loudest moment's level (0…1, as the pill draws it), so a silent recording can be told from a quiet one.
    pub fn peak_level(&self) -> f32 {
        let window = (self.sample_rate as usize / 20).max(1);
        self.samples
            .chunks(window)
            .map(|chunk| {
                let floats: Vec<f32> = chunk.iter().map(|sample| *sample as f32 / 32768.0).collect();
                level_of(&floats)
            })
            .fold(0.0, f32::max)
    }

    /// A WAV file of these samples.
    pub fn to_wav(&self) -> Vec<u8> {
        wav_bytes(&self.samples, self.sample_rate)
    }

    /// WAV files of at most `maximum_seconds` each (Sarvam's REST listening takes under 30 s; the Mac cuts at 28).
    pub fn wav_chunks(&self, maximum_seconds: u32) -> Vec<Vec<u8>> {
        let per_chunk = (maximum_seconds.max(1) * self.sample_rate.max(1)) as usize;
        if self.samples.len() <= per_chunk {
            return vec![self.to_wav()];
        }
        self.samples.chunks(per_chunk).map(|chunk| wav_bytes(chunk, self.sample_rate)).collect()
    }

    /// Reads a WAV file: 8, 16, 24 or 32-bit PCM, or 32-bit float, any channels and rate. Converted to 16 kHz mono.
    pub fn from_wav(bytes: &[u8]) -> Result<Audio> {
        if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
            bail!("That isn't a WAV file.");
        }
        let mut position = 12;
        let mut format: Option<(u16, u16, u32, u16)> = None;
        let mut data: Option<&[u8]> = None;
        while position + 8 <= bytes.len() {
            let id = &bytes[position..position + 4];
            let size = u32::from_le_bytes([bytes[position + 4], bytes[position + 5], bytes[position + 6], bytes[position + 7]]) as usize;
            let start = position + 8;
            let end = (start + size).min(bytes.len());
            if id == b"fmt " && end - start >= 16 {
                let chunk = &bytes[start..end];
                let mut tag = u16::from_le_bytes([chunk[0], chunk[1]]);
                let channels = u16::from_le_bytes([chunk[2], chunk[3]]);
                let rate = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
                let bits = u16::from_le_bytes([chunk[14], chunk[15]]);
                // WAVE_FORMAT_EXTENSIBLE: the real tag is the first two bytes of the sub-format.
                if tag == 0xFFFE && chunk.len() >= 26 {
                    tag = u16::from_le_bytes([chunk[24], chunk[25]]);
                }
                format = Some((tag, channels, rate, bits));
            } else if id == b"data" {
                data = Some(&bytes[start..end]);
            }
            position = start + size + (size & 1);
        }
        let (tag, channels, rate, bits) = format.ok_or_else(|| anyhow!("The WAV file has no format."))?;
        let data = data.ok_or_else(|| anyhow!("The WAV file has no sound in it."))?;
        if channels == 0 || rate == 0 {
            bail!("The WAV file's format is broken.");
        }
        let frame_bytes = (bits as usize / 8) * channels as usize;
        if frame_bytes == 0 {
            bail!("The WAV file's format is broken.");
        }
        let read_one = |piece: &[u8]| -> Option<f32> {
            match (tag, bits) {
                (1, 8) => Some((piece[0] as f32 - 128.0) / 128.0),
                (1, 16) => Some(i16::from_le_bytes([piece[0], piece[1]]) as f32 / 32768.0),
                (1, 24) => Some((((piece[2] as i32) << 24 | (piece[1] as i32) << 16 | (piece[0] as i32) << 8) >> 8) as f32 / 8_388_608.0),
                (1, 32) => Some(i32::from_le_bytes([piece[0], piece[1], piece[2], piece[3]]) as f32 / 2_147_483_648.0),
                (3, 32) => Some(f32::from_le_bytes([piece[0], piece[1], piece[2], piece[3]])),
                _ => None,
            }
        };
        let sample_bytes = bits as usize / 8;
        let mut mono = Vec::with_capacity(data.len() / frame_bytes);
        for frame in data.chunks_exact(frame_bytes) {
            let mut sum = 0.0;
            for channel in 0..channels as usize {
                sum += read_one(&frame[channel * sample_bytes..(channel + 1) * sample_bytes]).ok_or_else(|| anyhow!("Theo can't read this kind of WAV file ({bits}-bit, format {tag})."))?;
            }
            mono.push(sum / channels as f32);
        }
        Ok(Audio::from_float(&mono, rate))
    }
}

fn wav_bytes(samples: &[i16], sample_rate: u32) -> Vec<u8> {
    let data_bytes = samples.len() * 2;
    let mut wav = Vec::with_capacity(44 + data_bytes);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_bytes as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(data_bytes as u32).to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

pub fn float_to_pcm16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16
}

/// Mono samples from one rate to another. Going down, each output sample is the average of the input it covers (a box
/// filter, enough for speech); going up, straight lines between samples.
pub fn resample(input: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if input.is_empty() || from_rate == 0 || to_rate == 0 {
        return vec![];
    }
    if from_rate == to_rate {
        return input.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let output_length = ((input.len() as f64) / ratio).floor().max(1.0) as usize;
    let mut output = Vec::with_capacity(output_length);
    for index in 0..output_length {
        let start = index as f64 * ratio;
        if ratio > 1.0 {
            let first = start.floor() as usize;
            let last = (((index + 1) as f64 * ratio).ceil() as usize).min(input.len()).max(first + 1);
            let piece = &input[first.min(input.len() - 1)..last.min(input.len())];
            output.push(piece.iter().sum::<f32>() / piece.len().max(1) as f32);
        } else {
            let left = start.floor() as usize;
            let right = (left + 1).min(input.len() - 1);
            let fraction = (start - left as f64) as f32;
            let left_value = input[left.min(input.len() - 1)];
            output.push(left_value + (input[right] - left_value) * fraction);
        }
    }
    output
}

/// The level the pill draws, 0…1: RMS on a decibel scale, -55 dB silent to -10 dB full (the Mac's `DictationTape.level`).
pub fn level_of(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f32 = samples.iter().map(|sample| sample * sample).sum();
    let rms = (sum / samples.len() as f32).sqrt();
    let decibels = 20.0 * rms.max(0.000_01).log10();
    ((decibels + 55.0) / 45.0).clamp(0.0, 1.0)
}

/// The microphones on this computer, by name (what Settings › Dictation lists). Empty where Theo has no microphone support.
pub fn input_devices() -> Vec<String> {
    #[cfg(windows)]
    {
        windows_mic::input_devices()
    }
    #[cfg(not(windows))]
    {
        vec![]
    }
}

/// The name of the microphone Windows uses by default, if there is one.
pub fn default_input_device() -> Option<String> {
    #[cfg(windows)]
    {
        windows_mic::default_input_device()
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// An open microphone. Dropping it without `stop` throws the recording away.
pub struct Recorder {
    #[cfg(windows)]
    inner: windows_mic::Running,
}

impl Recorder {
    /// Opens `device` (a name from [`input_devices`]), or the default microphone. A device that's gone falls back to the default.
    pub fn start(device: Option<String>) -> Result<Recorder> {
        #[cfg(windows)]
        {
            Ok(Recorder { inner: windows_mic::Running::start(device.filter(|name| !name.trim().is_empty()))? })
        }
        #[cfg(not(windows))]
        {
            let _ = device;
            bail!("Theo can only use the microphone on Windows in this build.")
        }
    }

    /// The live level, 0…1.
    pub fn level(&self) -> f32 {
        #[cfg(windows)]
        {
            self.inner.level()
        }
        #[cfg(not(windows))]
        {
            0.0
        }
    }

    /// How long it has been recording.
    pub fn seconds(&self) -> f64 {
        #[cfg(windows)]
        {
            self.inner.seconds()
        }
        #[cfg(not(windows))]
        {
            0.0
        }
    }

    /// Closes the microphone and hands back what it heard.
    pub fn stop(self) -> Result<Audio> {
        #[cfg(windows)]
        {
            self.inner.stop()
        }
        #[cfg(not(windows))]
        {
            bail!("Theo can only use the microphone on Windows in this build.")
        }
    }
}

/// The words for a microphone that didn't open.
pub fn microphone_problem(detail: &str) -> String {
    let lower = detail.to_lowercase();
    if lower.contains("denied") || lower.contains("access") || lower.contains("0x80070005") {
        "Windows isn't letting apps use the microphone. Turn on Settings › Privacy & security › Microphone › \"Let desktop apps access your microphone\".".to_string()
    } else if lower.contains("no input") || lower.contains("not found") || lower.contains("no microphone") || lower.contains("no default") {
        "No microphone found. Plug one in, or pick another in Settings › Dictation.".to_string()
    } else {
        format!("The microphone didn't start ({detail}).")
    }
}

#[cfg(windows)]
mod windows_mic {
    use super::*;
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    pub fn input_devices() -> Vec<String> {
        let host = cpal::default_host();
        host.input_devices().map(|devices| devices.filter_map(|device| device.name().ok()).collect()).unwrap_or_default()
    }

    pub fn default_input_device() -> Option<String> {
        cpal::default_host().default_input_device().and_then(|device| device.name().ok())
    }

    struct Shared {
        samples: Mutex<Vec<f32>>,
        level_bits: AtomicU32,
        rate: AtomicU32,
    }

    pub struct Running {
        shared: Arc<Shared>,
        stop: Option<mpsc::Sender<()>>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    fn take_frames<T: Copy>(data: &[T], channels: usize, convert: impl Fn(T) -> f32, shared: &Shared) {
        let channels = channels.max(1);
        let mono: Vec<f32> = data.chunks(channels).map(|frame| frame.iter().map(|sample| convert(*sample)).sum::<f32>() / frame.len() as f32).collect();
        shared.level_bits.store(level_of(&mono).to_bits(), Ordering::Relaxed);
        let rate = shared.rate.load(Ordering::Relaxed).max(1) as usize;
        let mut samples = shared.samples.lock().unwrap();
        if samples.len() < rate * MAXIMUM_SECONDS as usize {
            samples.extend_from_slice(&mono);
        }
    }

    impl Running {
        pub fn start(device_name: Option<String>) -> Result<Running> {
            let shared = Arc::new(Shared { samples: Mutex::new(Vec::new()), level_bits: AtomicU32::new(0), rate: AtomicU32::new(48_000) });
            let (ready_sender, ready_receiver) = mpsc::channel::<std::result::Result<(), String>>();
            let (stop_sender, stop_receiver) = mpsc::channel::<()>();
            let thread_shared = shared.clone();
            let thread = std::thread::Builder::new().name("theo-microphone".into()).spawn(move || {
                let host = cpal::default_host();
                let named = device_name.as_ref().and_then(|wanted| host.input_devices().ok().and_then(|mut devices| devices.find(|device| device.name().map(|name| &name == wanted).unwrap_or(false))));
                let Some(device) = named.or_else(|| host.default_input_device()) else {
                    let _ = ready_sender.send(Err("no microphone".into()));
                    return;
                };
                let config = match device.default_input_config() {
                    Ok(config) => config,
                    Err(error) => {
                        let _ = ready_sender.send(Err(error.to_string()));
                        return;
                    }
                };
                let channels = config.channels() as usize;
                thread_shared.rate.store(config.sample_rate().0, Ordering::Relaxed);
                let stream_config: cpal::StreamConfig = config.clone().into();
                let on_error = |error: cpal::StreamError| eprintln!("[dictation] microphone: {error}");
                let callback_shared = thread_shared.clone();
                let stream = match config.sample_format() {
                    cpal::SampleFormat::F32 => device.build_input_stream(&stream_config, move |data: &[f32], _: &cpal::InputCallbackInfo| take_frames(data, channels, |s| s, &callback_shared), on_error, None),
                    cpal::SampleFormat::I16 => device.build_input_stream(&stream_config, move |data: &[i16], _: &cpal::InputCallbackInfo| take_frames(data, channels, |s| s as f32 / 32768.0, &callback_shared), on_error, None),
                    cpal::SampleFormat::U16 => device.build_input_stream(&stream_config, move |data: &[u16], _: &cpal::InputCallbackInfo| take_frames(data, channels, |s| (s as f32 - 32768.0) / 32768.0, &callback_shared), on_error, None),
                    cpal::SampleFormat::I32 => device.build_input_stream(&stream_config, move |data: &[i32], _: &cpal::InputCallbackInfo| take_frames(data, channels, |s| s as f32 / 2_147_483_648.0, &callback_shared), on_error, None),
                    other => {
                        let _ = ready_sender.send(Err(format!("the microphone's format ({other:?}) isn't one Theo reads")));
                        return;
                    }
                };
                let stream = match stream {
                    Ok(stream) => stream,
                    Err(error) => {
                        let _ = ready_sender.send(Err(error.to_string()));
                        return;
                    }
                };
                if let Err(error) = stream.play() {
                    let _ = ready_sender.send(Err(error.to_string()));
                    return;
                }
                let _ = ready_sender.send(Ok(()));
                // Held open until stop (or the Recorder is dropped, which drops the sender).
                let _ = stop_receiver.recv();
                drop(stream);
            })?;
            match ready_receiver.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(())) => Ok(Running { shared, stop: Some(stop_sender), thread: Some(thread) }),
                Ok(Err(problem)) => {
                    let _ = thread.join();
                    Err(anyhow!(microphone_problem(&problem)))
                }
                Err(_) => {
                    drop(stop_sender);
                    Err(anyhow!("The microphone took too long to open."))
                }
            }
        }

        pub fn level(&self) -> f32 {
            f32::from_bits(self.shared.level_bits.load(Ordering::Relaxed))
        }

        pub fn seconds(&self) -> f64 {
            let rate = self.shared.rate.load(Ordering::Relaxed).max(1);
            self.shared.samples.lock().unwrap().len() as f64 / rate as f64
        }

        fn close(&mut self) {
            if let Some(stop) = self.stop.take() {
                let _ = stop.send(());
            }
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }

        pub fn stop(mut self) -> Result<Audio> {
            self.close();
            let samples = std::mem::take(&mut *self.shared.samples.lock().unwrap());
            let rate = self.shared.rate.load(Ordering::Relaxed);
            Ok(Audio::from_float(&samples, rate))
        }
    }

    impl Drop for Running {
        fn drop(&mut self) {
            self.close();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(seconds: f32, rate: u32, amplitude: f32) -> Vec<f32> {
        (0..(seconds * rate as f32) as usize).map(|index| amplitude * (index as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin()).collect()
    }

    #[test]
    fn wav_round_trips() {
        let audio = Audio::from_float(&tone(0.5, 16_000, 0.5), 16_000);
        let wav = audio.to_wav();
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(wav.len(), 44 + audio.samples.len() * 2);
        let back = Audio::from_wav(&wav).unwrap();
        assert_eq!(back, audio);
        assert!((back.duration_seconds() - 0.5).abs() < 0.01);
    }

    #[test]
    fn stereo_48k_becomes_16k_mono() {
        let left = tone(1.0, 48_000, 0.4);
        let mut stereo = vec![];
        for sample in &left {
            stereo.extend_from_slice(&float_to_pcm16(*sample).to_le_bytes());
            stereo.extend_from_slice(&float_to_pcm16(*sample).to_le_bytes());
        }
        let mut wav = wav_bytes(&[], 48_000);
        // Rewrite the header for two channels and append the data.
        wav[22] = 2;
        wav[28..32].copy_from_slice(&(48_000u32 * 4).to_le_bytes());
        wav[32] = 4;
        wav[40..44].copy_from_slice(&(stereo.len() as u32).to_le_bytes());
        wav[4..8].copy_from_slice(&(36 + stereo.len() as u32).to_le_bytes());
        wav.extend_from_slice(&stereo);
        let audio = Audio::from_wav(&wav).unwrap();
        assert_eq!(audio.sample_rate, 16_000);
        assert!((audio.duration_seconds() - 1.0).abs() < 0.01, "{}", audio.duration_seconds());
        assert!(audio.peak_level() > 0.8);
    }

    #[test]
    fn float_wavs_and_odd_chunks_are_read() {
        let samples = tone(0.25, 8_000, 0.3);
        let mut data = vec![];
        for sample in &samples {
            data.extend_from_slice(&sample.to_le_bytes());
        }
        let mut wav = b"RIFF\0\0\0\0WAVE".to_vec();
        // An odd-sized chunk before fmt, padded to even.
        wav.extend_from_slice(b"LIST");
        wav.extend_from_slice(&3u32.to_le_bytes());
        wav.extend_from_slice(b"abc\0");
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&3u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&8_000u32.to_le_bytes());
        wav.extend_from_slice(&32_000u32.to_le_bytes());
        wav.extend_from_slice(&4u16.to_le_bytes());
        wav.extend_from_slice(&32u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wav.extend_from_slice(&data);
        let audio = Audio::from_wav(&wav).unwrap();
        assert!((audio.duration_seconds() - 0.25).abs() < 0.01);
        assert!(Audio::from_wav(b"not a wav at all").is_err());
    }

    #[test]
    fn levels_follow_the_macs_scale() {
        assert_eq!(level_of(&[]), 0.0);
        assert_eq!(level_of(&vec![0.0; 100]), 0.0);
        assert!(level_of(&tone(0.1, 16_000, 0.9)) > 0.9);
        let quiet = level_of(&tone(0.1, 16_000, 0.01));
        assert!(quiet > 0.0 && quiet < 0.5, "{quiet}");
        assert_eq!(Audio::from_samples(vec![0; 16_000]).peak_level(), 0.0);
    }

    #[test]
    fn long_audio_is_cut_into_chunks() {
        let audio = Audio::from_samples(vec![0; 16_000 * 61]);
        let chunks = audio.wav_chunks(28);
        assert_eq!(chunks.len(), 3);
        assert_eq!(Audio::from_wav(&chunks[0]).unwrap().samples.len(), 16_000 * 28);
        assert_eq!(Audio::from_wav(&chunks[2]).unwrap().samples.len(), 16_000 * 5);
        assert_eq!(Audio::from_samples(vec![0; 100]).wav_chunks(28).len(), 1);
    }

    #[test]
    fn resampling_keeps_length_and_shape() {
        let up = resample(&[0.0, 1.0], 8_000, 16_000);
        assert_eq!(up.len(), 4);
        assert!((up[1] - 0.5).abs() < 0.01);
        assert_eq!(resample(&tone(1.0, 44_100, 0.5), 44_100, 16_000).len(), 16_000);
        assert!(resample(&[], 48_000, 16_000).is_empty());
    }

    #[test]
    fn microphone_problems_are_plain() {
        assert!(microphone_problem("Access is denied. (0x80070005)").contains("Privacy"));
        assert!(microphone_problem("no microphone").contains("No microphone"));
        #[cfg(not(windows))]
        assert!(Recorder::start(None).is_err());
    }
}
