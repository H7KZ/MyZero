use embedded_graphics::{
    mono_font::{iso_8859_2::FONT_6X10, MonoTextStyle, MonoTextStyleBuilder},
    pixelcolor::BinaryColor,
    prelude::*,
    text::{Baseline, Text},
};
use linux_embedded_hal::I2cdev;
use sh1106::{mode::GraphicsMode, Builder};

pub type Display = GraphicsMode<sh1106::interface::I2cInterface<I2cdev>>;

pub fn init() -> Display {
    let i2c =
        I2cdev::new("/dev/i2c-1").expect("Cannot open /dev/i2c-1 — enable I2C via raspi-config");
    let mut display: Display = Builder::new().connect_i2c(i2c).into();
    display.init().expect("Display init failed");
    display.flush().expect("Display flush failed");
    display
}

/// Blanks the screen (OLED draws no current for dark pixels).
pub fn sleep(display: &mut Display) {
    display.clear();
    display.flush().expect("Flush failed");
}

/// Renders header + departure rows. Each string must be ≤21 chars (caller's responsibility).
pub fn render_board(display: &mut Display, header: &str, rows: &[String]) {
    display.clear();
    let s = style();
    put(display, s, header, 0);
    for (i, row) in rows.iter().enumerate() {
        put(display, s, row, (i as i32 + 1) * 12);
    }
    display.flush().expect("Flush failed");
}

/// Single status line (startup, error, idle hint).
pub fn show_status(display: &mut Display, msg: &str) {
    display.clear();
    put(display, style(), msg, 0);
    display.flush().expect("Flush failed");
}

fn style() -> MonoTextStyle<'static, BinaryColor> {
    MonoTextStyleBuilder::new()
        .font(&FONT_6X10)
        .text_color(BinaryColor::On)
        .build()
}

fn put(display: &mut Display, style: MonoTextStyle<'static, BinaryColor>, text: &str, y: i32) {
    Text::with_baseline(text, Point::new(0, y), style, Baseline::Top)
        .draw(display)
        .expect("Draw failed");
}
