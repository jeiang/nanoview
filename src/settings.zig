//! What the user can set, with the defaults. One `Settings` lives in `State`.

pub const FitMode = enum { whole, width, height, fill };
pub const AfterTrash = enum { next, previous };

pub const Settings = struct {
    /// What "fit" shows: the whole picture, or one side filling the window.
    fit_mode: FitMode = .whole,
    /// Fit may enlarge a picture smaller than the window.
    fit_upscale: bool = false,
    /// Off: enlarged pictures show their pixels as squares.
    smooth: bool = true,
    /// The next picture keeps the zoom and position of the last.
    zoom_lock: bool = false,
    /// A checkerboard behind the picture, to tell transparency from white.
    checkerboard: bool = false,
    /// One zoom step, as a percentage added to the scale.
    zoom_step_percent: u32 = 25,
    /// Stepping past the last picture goes to the first, and back.
    loop: bool = true,
    slideshow_seconds: u32 = 5,
    slideshow_reverse: bool = false,
    /// Ask before a picture goes to the Trash.
    trash_confirm: bool = false,
    /// The picture shown after one is trashed.
    after_trash: AfterTrash = .next,
};
