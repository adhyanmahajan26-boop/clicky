//! What Clicky sees: a screenshot of every monitor, scaled down like the Mac's (`ScreenCaptureService`, `ClaudeImageSizing`),
//! numbered the Mac's way (SCREEN 1 is the monitor the cursor is on, the rest left to right), each with its header line
//! (`SCREEN 1 "Display 1" (main, cursor here) image 1568x882 px`), and the way back from a pixel of an image to a point on
//! that monitor.
//!
//! Every position here is in physical pixels of the virtual desktop (Windows' own coordinates for a per-monitor DPI aware
//! program; the primary monitor's top-left is 0,0). The overlay divides by each monitor's scale to place things.
//!
//! Capturing is Windows only in this build (GDI `BitBlt` per monitor, with the thread made per-monitor DPI aware so a 150 %
//! screen is captured at its real size). Linux and the Mac get "can't see the screen here".

use base64::Engine as _;
use serde_json::{json, Value};

/// The longest edge an image is sent at: the Mac's standard tier (`ImageTier.standard.maxEdge`), which every vision model
/// takes without scaling it again.
pub const MAXIMUM_IMAGE_EDGE: u32 = 1568;
pub const JPEG_QUALITY: u8 = 85;

/// A monitor, in physical pixels of the virtual desktop.
#[derive(Clone, Debug, PartialEq)]
pub struct Monitor {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    /// 1.0 at 100 %, 1.5 at 150 %.
    pub scale: f64,
    pub primary: bool,
    pub name: String,
}

impl Monitor {
    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && y >= self.y && (x as i64) < self.x as i64 + self.width as i64 && (y as i64) < self.y as i64 + self.height as i64
    }

    pub fn to_json(&self) -> Value {
        json!({"x": self.x, "y": self.y, "width": self.width, "height": self.height, "scale": self.scale, "primary": self.primary, "name": self.name})
    }

    pub fn from_json(value: &Value) -> Option<Monitor> {
        Some(Monitor {
            x: value["x"].as_i64().unwrap_or(0) as i32,
            y: value["y"].as_i64().unwrap_or(0) as i32,
            width: value["width"].as_u64().filter(|w| *w > 0)? as u32,
            height: value["height"].as_u64().filter(|h| *h > 0)? as u32,
            scale: value["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0),
            primary: value["primary"].as_bool().unwrap_or(false),
            name: value["name"].as_str().unwrap_or("Display").to_string(),
        })
    }
}

/// One monitor's picture as the brain gets it.
#[derive(Clone, Debug)]
pub struct Screen {
    /// SCREEN n: 1 is the cursor's monitor.
    pub number: usize,
    pub monitor: Monitor,
    pub cursor_here: bool,
    /// "main", "left of main", …
    pub position: String,
    pub image_width: u32,
    pub image_height: u32,
    pub jpeg: Vec<u8>,
}

impl Screen {
    /// `SCREEN 1 "Display 1" (main, cursor here) image 1568x882 px`, the Mac's `ElementListFormatter.header`.
    pub fn header(&self) -> String {
        let position = if self.cursor_here { format!("{}, cursor here", self.position) } else { self.position.clone() };
        format!("SCREEN {} \"{}\" ({}) image {}x{} px", self.number, self.monitor.name.replace('"', "'"), position, self.image_width, self.image_height)
    }

    pub fn jpeg_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(&self.jpeg)
    }

    pub fn summary(&self) -> Value {
        json!({"number": self.number, "header": self.header(), "monitor": self.monitor.to_json(), "imageWidth": self.image_width, "imageHeight": self.image_height, "jpegBytes": self.jpeg.len()})
    }
}

/// Where a monitor sits next to the primary one, in the Mac's words (`DisplayInfo.positionDescription`).
pub fn position_description(monitor: &Monitor, primary: &Monitor) -> String {
    if monitor.primary || monitor == primary {
        return "main".into();
    }
    let (left, top) = (primary.x as i64, primary.y as i64);
    let (right, bottom) = (left + primary.width as i64, top + primary.height as i64);
    let (m_left, m_top) = (monitor.x as i64, monitor.y as i64);
    let (m_right, m_bottom) = (m_left + monitor.width as i64, m_top + monitor.height as i64);
    if m_right <= left + 1 {
        "left of main".into()
    } else if m_left >= right - 1 {
        "right of main".into()
    } else if m_bottom <= top + 1 {
        "above main".into()
    } else if m_top >= bottom - 1 {
        "below main".into()
    } else {
        "overlapping main".into()
    }
}

/// The monitors in SCREEN order: the cursor's first, then the rest left to right (then top to bottom). Each with whether
/// the cursor is on it. A cursor on no monitor counts as on the primary.
pub fn screen_order(monitors: &[Monitor], cursor: (i32, i32)) -> Vec<(Monitor, bool)> {
    if monitors.is_empty() {
        return vec![];
    }
    let cursor_index = monitors
        .iter()
        .position(|monitor| monitor.contains(cursor.0, cursor.1))
        .or_else(|| monitors.iter().position(|monitor| monitor.primary))
        .unwrap_or(0);
    let mut rest: Vec<&Monitor> = monitors.iter().enumerate().filter(|(index, _)| *index != cursor_index).map(|(_, monitor)| monitor).collect();
    rest.sort_by_key(|monitor| (monitor.x, monitor.y));
    let mut ordered = vec![(monitors[cursor_index].clone(), true)];
    ordered.extend(rest.into_iter().map(|monitor| (monitor.clone(), false)));
    ordered
}

/// The size an image is sent at: the same shape, its longest edge at most `maximum_edge`.
pub fn scaled_size(width: u32, height: u32, maximum_edge: u32) -> (u32, u32) {
    let longest = width.max(height);
    if longest <= maximum_edge || longest == 0 {
        return (width.max(1), height.max(1));
    }
    let factor = maximum_edge as f64 / longest as f64;
    (((width as f64 * factor).round() as u32).max(1), ((height as f64 * factor).round() as u32).max(1))
}

/// A pixel of a screen's image to a physical point on its monitor, kept inside the monitor.
pub fn image_point_to_physical(x: i64, y: i64, image_width: u32, image_height: u32, monitor: &Monitor) -> (i32, i32) {
    let scale_x = monitor.width as f64 / image_width.max(1) as f64;
    let scale_y = monitor.height as f64 / image_height.max(1) as f64;
    let clamped_x = (x as f64).clamp(0.0, image_width.saturating_sub(1) as f64);
    let clamped_y = (y as f64).clamp(0.0, image_height.saturating_sub(1) as f64);
    let physical_x = monitor.x as f64 + (clamped_x * scale_x).round();
    let physical_y = monitor.y as f64 + (clamped_y * scale_y).round();
    (physical_x as i32, physical_y as i32)
}

/// A box in a screen's image to a physical box on its monitor (x, y, width, height), kept inside the monitor.
pub fn image_box_to_physical(x: i64, y: i64, width: i64, height: i64, image_width: u32, image_height: u32, monitor: &Monitor) -> (i32, i32, i32, i32) {
    let (left, top) = image_point_to_physical(x, y, image_width, image_height, monitor);
    let (right, bottom) = image_point_to_physical(x + width, y + height, image_width, image_height, monitor);
    (left, top, (right - left).max(1), (bottom - top).max(1))
}

/// A physical point to where it sits in the overlay window that covers `monitor` (CSS pixels of that window).
pub fn physical_to_overlay(x: i32, y: i32, monitor: &Monitor) -> (f64, f64) {
    ((x - monitor.x) as f64 / monitor.scale, (y - monitor.y) as f64 / monitor.scale)
}

/// Scales an RGB picture down to the size the brain gets and encodes it as JPEG.
pub fn encode_for_brain(picture: &image::RgbImage) -> Result<(Vec<u8>, u32, u32), String> {
    let (width, height) = scaled_size(picture.width(), picture.height(), MAXIMUM_IMAGE_EDGE);
    let resized;
    let source = if (width, height) == (picture.width(), picture.height()) {
        picture
    } else {
        resized = image::imageops::resize(picture, width, height, image::imageops::FilterType::Triangle);
        &resized
    };
    let mut jpeg = vec![];
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, JPEG_QUALITY);
    encoder.encode_image(source).map_err(|e| format!("Couldn't encode the screenshot: {e}"))?;
    Ok((jpeg, width, height))
}

/// Builds the screens from captured pictures (monitor, RGB picture), in SCREEN order.
pub fn screens_from_pictures(pictures: Vec<(Monitor, image::RgbImage)>, cursor: (i32, i32)) -> Result<Vec<Screen>, String> {
    let monitors: Vec<Monitor> = pictures.iter().map(|(monitor, _)| monitor.clone()).collect();
    let primary = monitors.iter().find(|monitor| monitor.primary).cloned().or_else(|| monitors.first().cloned());
    let mut screens = vec![];
    for (index, (monitor, cursor_here)) in screen_order(&monitors, cursor).into_iter().enumerate() {
        let Some((_, picture)) = pictures.iter().find(|(captured, _)| *captured == monitor) else { continue };
        let (jpeg, image_width, image_height) = encode_for_brain(picture)?;
        let position = primary.as_ref().map(|primary| position_description(&monitor, primary)).unwrap_or_else(|| "main".into());
        screens.push(Screen { number: index + 1, monitor, cursor_here, position, image_width, image_height, jpeg });
    }
    Ok(screens)
}

/// A picture file given to `clickyTest`, as one screen on `monitor` (default: a 1920x1080 primary at 0,0, 100 %).
pub fn screen_from_file(path: &std::path::Path, number: usize, monitor: Option<Monitor>) -> Result<Screen, String> {
    let picture = image::open(path).map_err(|e| format!("Couldn't read the picture {}: {e}", path.display()))?.to_rgb8();
    let monitor = monitor.unwrap_or(Monitor { x: 0, y: 0, width: picture.width(), height: picture.height(), scale: 1.0, primary: number == 1, name: format!("Display {number}") });
    let (jpeg, image_width, image_height) = encode_for_brain(&picture)?;
    Ok(Screen { number, position: if monitor.primary { "main".into() } else { "right of main".into() }, cursor_here: number == 1, monitor, image_width, image_height, jpeg })
}

/// Every monitor right now, with the cursor's position (physical pixels).
pub fn monitors_and_cursor() -> Result<(Vec<Monitor>, (i32, i32)), String> {
    platform::monitors_and_cursor()
}

/// Captures every monitor and returns the screens in SCREEN order.
pub fn capture_all() -> Result<Vec<Screen>, String> {
    let (pictures, cursor) = platform::capture()?;
    if pictures.is_empty() {
        return Err("No monitors were found to capture.".into());
    }
    screens_from_pictures(pictures, cursor)
}

pub fn can_capture() -> bool {
    cfg!(windows)
}

#[cfg(not(windows))]
mod platform {
    use super::Monitor;

    pub fn monitors_and_cursor() -> Result<(Vec<Monitor>, (i32, i32)), String> {
        Err("Clicky can only see the screen on Windows in this build.".into())
    }

    pub fn capture() -> Result<(Vec<(Monitor, image::RgbImage)>, (i32, i32)), String> {
        Err("Clicky can only see the screen on Windows in this build.".into())
    }
}

#[cfg(windows)]
mod platform {
    use super::Monitor;
    use windows_sys::Win32::Foundation::{BOOL, LPARAM, POINT, RECT};
    use windows_sys::Win32::Graphics::Gdi::*;
    use windows_sys::Win32::UI::HiDpi::{GetDpiForMonitor, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI};
    use windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos;

    /// Makes this thread per-monitor DPI aware for as long as it lives (put back after), so monitor sizes, the cursor and
    /// the pictures are in physical pixels even in a program that isn't DPI aware itself (theod).
    struct PhysicalPixels(isize);

    impl PhysicalPixels {
        fn begin() -> Self {
            Self(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) } as isize)
        }
    }

    impl Drop for PhysicalPixels {
        fn drop(&mut self) {
            if self.0 != 0 {
                unsafe { SetThreadDpiAwarenessContext(self.0 as _) };
            }
        }
    }

    unsafe extern "system" fn collect_monitor(monitor: HMONITOR, _dc: HDC, _rect: *mut RECT, data: LPARAM) -> BOOL {
        let found = &mut *(data as *mut Vec<HMONITOR>);
        found.push(monitor);
        1
    }

    fn list_monitors() -> Vec<Monitor> {
        let mut handles: Vec<HMONITOR> = vec![];
        unsafe {
            EnumDisplayMonitors(std::ptr::null_mut(), std::ptr::null(), Some(collect_monitor), &mut handles as *mut Vec<HMONITOR> as LPARAM);
        }
        let mut monitors = vec![];
        for (index, handle) in handles.into_iter().enumerate() {
            let mut info: MONITORINFOEXW = unsafe { std::mem::zeroed() };
            info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
            if unsafe { GetMonitorInfoW(handle, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) } == 0 {
                continue;
            }
            let rect = info.monitorInfo.rcMonitor;
            let (mut dpi_x, mut dpi_y) = (96u32, 96u32);
            let scale = if unsafe { GetDpiForMonitor(handle, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) } == 0 { dpi_x as f64 / 96.0 } else { 1.0 };
            let device_end = info.szDevice.iter().position(|c| *c == 0).unwrap_or(info.szDevice.len());
            let device = String::from_utf16_lossy(&info.szDevice[..device_end]);
            // "\\.\DISPLAY2" → "Display 2"; Windows' friendly monitor names need the display configuration API.
            let digits: String = device.chars().filter(|c| c.is_ascii_digit()).collect();
            let name = if digits.is_empty() { format!("Display {}", index + 1) } else { format!("Display {digits}") };
            monitors.push(Monitor {
                x: rect.left,
                y: rect.top,
                width: (rect.right - rect.left).max(1) as u32,
                height: (rect.bottom - rect.top).max(1) as u32,
                scale,
                primary: info.monitorInfo.dwFlags & 1 != 0,
                name,
            });
        }
        monitors
    }

    fn cursor() -> (i32, i32) {
        let mut point = POINT { x: 0, y: 0 };
        unsafe { GetCursorPos(&mut point) };
        (point.x, point.y)
    }

    pub fn monitors_and_cursor() -> Result<(Vec<Monitor>, (i32, i32)), String> {
        let _physical = PhysicalPixels::begin();
        Ok((list_monitors(), cursor()))
    }

    fn capture_monitor(monitor: &Monitor) -> Result<image::RgbImage, String> {
        let (width, height) = (monitor.width as i32, monitor.height as i32);
        unsafe {
            let screen = GetDC(std::ptr::null_mut());
            if screen.is_null() {
                return Err("Couldn't open the screen to capture it.".into());
            }
            let memory = CreateCompatibleDC(screen);
            let bitmap = CreateCompatibleBitmap(screen, width, height);
            let previous = SelectObject(memory, bitmap);
            // CAPTUREBLT takes layered windows too (most of what's on a modern desktop).
            let copied = BitBlt(memory, 0, 0, width, height, screen, monitor.x, monitor.y, SRCCOPY | CAPTUREBLT);
            let mut header: BITMAPINFO = std::mem::zeroed();
            header.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
            header.bmiHeader.biWidth = width;
            // Negative: rows top to bottom.
            header.bmiHeader.biHeight = -height;
            header.bmiHeader.biPlanes = 1;
            header.bmiHeader.biBitCount = 32;
            header.bmiHeader.biCompression = BI_RGB;
            let mut pixels = vec![0u8; width as usize * height as usize * 4];
            SelectObject(memory, previous);
            let lines = GetDIBits(memory, bitmap, 0, height as u32, pixels.as_mut_ptr() as *mut _, &mut header, DIB_RGB_COLORS);
            DeleteObject(bitmap);
            DeleteDC(memory);
            ReleaseDC(std::ptr::null_mut(), screen);
            if copied == 0 || lines == 0 {
                return Err("Windows didn't let Theo capture the screen (a secure desktop or a locked screen?).".into());
            }
            // BGRA → RGB.
            let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
            for pixel in pixels.chunks_exact(4) {
                rgb.extend_from_slice(&[pixel[2], pixel[1], pixel[0]]);
            }
            image::RgbImage::from_raw(width as u32, height as u32, rgb).ok_or_else(|| "The screenshot came back the wrong size.".to_string())
        }
    }

    pub fn capture() -> Result<(Vec<(Monitor, image::RgbImage)>, (i32, i32)), String> {
        let _physical = PhysicalPixels::begin();
        let monitors = list_monitors();
        let cursor = cursor();
        let mut pictures = vec![];
        for monitor in monitors {
            let picture = capture_monitor(&monitor)?;
            pictures.push((monitor, picture));
        }
        Ok((pictures, cursor))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(x: i32, y: i32, width: u32, height: u32, scale: f64, primary: bool) -> Monitor {
        Monitor { x, y, width, height, scale, primary, name: "Display".into() }
    }

    #[test]
    fn cursor_screen_is_first_then_left_to_right() {
        let left = monitor(-1920, 0, 1920, 1080, 1.0, false);
        let main = monitor(0, 0, 3840, 2160, 1.5, true);
        let right = monitor(3840, 200, 2560, 1440, 1.0, false);
        let order = screen_order(&[main.clone(), right.clone(), left.clone()], (4000, 600));
        assert_eq!(order.iter().map(|(m, here)| (m.x, *here)).collect::<Vec<_>>(), vec![(3840, true), (-1920, false), (0, false)]);
        // A cursor off every monitor counts as on the primary.
        assert_eq!(screen_order(&[left.clone(), main.clone()], (99_999, 0))[0].0, main);
        assert_eq!(position_description(&left, &main), "left of main");
        assert_eq!(position_description(&right, &main), "right of main");
        assert_eq!(position_description(&main, &main), "main");
        assert_eq!(position_description(&monitor(0, -1080, 1920, 1080, 1.0, false), &main), "above main");
    }

    #[test]
    fn images_are_scaled_like_the_mac() {
        assert_eq!(scaled_size(3840, 2160, MAXIMUM_IMAGE_EDGE), (1568, 882));
        assert_eq!(scaled_size(1280, 720, MAXIMUM_IMAGE_EDGE), (1280, 720));
        assert_eq!(scaled_size(1080, 1920, MAXIMUM_IMAGE_EDGE), (882, 1568));
    }

    #[test]
    fn image_pixels_map_to_the_right_monitor_at_any_scale() {
        // A 4K monitor at 150 % to the right of the primary, sent at 1568x882.
        let tall = monitor(1920, 0, 3840, 2160, 1.5, false);
        assert_eq!(image_point_to_physical(784, 441, 1568, 882, &tall), (1920 + 1920, 1080));
        assert_eq!(image_point_to_physical(0, 0, 1568, 882, &tall), (1920, 0));
        // Off the image: kept on the monitor.
        let (x, y) = image_point_to_physical(5000, -3, 1568, 882, &tall);
        assert!(tall.contains(x, y));
        // Into the overlay window over that monitor, in its CSS pixels.
        assert_eq!(physical_to_overlay(3840, 1080, &tall), (1280.0, 720.0));
        // A monitor left of the primary has negative coordinates.
        let left = monitor(-1920, -200, 1920, 1080, 1.0, false);
        assert_eq!(image_point_to_physical(960, 540, 1920, 1080, &left), (-960, 340));
        assert_eq!(image_box_to_physical(100, 100, 200, 50, 1568, 882, &tall), (1920 + 245, 245, 490, 122));
    }

    #[test]
    fn header_reads_like_the_mac() {
        let screen = Screen { number: 1, monitor: monitor(0, 0, 1920, 1080, 1.0, true), cursor_here: true, position: "main".into(), image_width: 1568, image_height: 882, jpeg: vec![] };
        assert_eq!(screen.header(), "SCREEN 1 \"Display\" (main, cursor here) image 1568x882 px");
    }

    #[test]
    fn pictures_become_numbered_jpegs() {
        let main = monitor(0, 0, 3200, 1800, 2.0, true);
        let side = monitor(3200, 0, 800, 600, 1.0, false);
        let screens = screens_from_pictures(vec![(main.clone(), image::RgbImage::new(3200, 1800)), (side.clone(), image::RgbImage::new(800, 600))], (3300, 10)).unwrap();
        assert_eq!(screens.len(), 2);
        assert_eq!((screens[0].number, screens[0].cursor_here, screens[0].monitor.x), (1, true, 3200));
        assert_eq!((screens[0].image_width, screens[0].image_height), (800, 600));
        assert_eq!((screens[1].image_width, screens[1].image_height), (1568, 882));
        assert_eq!(screens[0].position, "right of main");
        assert_eq!(&screens[1].jpeg[..2], &[0xFF, 0xD8]);
    }
}
