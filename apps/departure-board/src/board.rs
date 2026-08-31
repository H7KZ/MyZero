// Formats departure data into fixed-width strings for the 128×64 OLED.
//
// FONT_6X10 → 6 px/char → 21 chars fit in 128 px.
// Row height 12 px (10 px font + 2 px gap) → 5 rows in 64 px.
//
// Layout:
//   row 0  "StopName        HH:MM"   header (15 + 1 + 5 = 21)
//   row 1  "LINE DESTINATION   MMm"  departure (4+1+11+1+4 = 21)
//   rows 2-4  same pattern

use chrono::Local;

use crate::api::Departure;

/// Header row: stop name (left) + clock or stop indicator (right). Always 21 chars.
///
/// Single stop:   "Bořislavka      12:34"
/// Multi-stop:    "Bořislavka       1/2 "  (index shown instead of clock)
pub fn header(stop_name: &str, index: usize, total: usize) -> String {
    let right = if total > 1 {
        format!("{}/{}", index + 1, total) // e.g. "1/2"
    } else {
        Local::now().format("%H:%M").to_string()
    };
    let name_width = 21 - 1 - right.len();
    let name: String = stop_name.chars().take(name_width).collect();
    format!("{:<width$} {}", name, right, width = name_width)
}

/// Renders up to `max` departure rows, each exactly 21 chars.
pub fn render(departures: &[Departure], max: usize) -> Vec<String> {
    departures.iter().take(max).map(departure_row).collect()
}

fn departure_row(dep: &Departure) -> String {
    let line: String = dep.line.chars().take(4).collect();
    let dest: String = dep.destination.chars().take(11).collect();
    let time = fmt_time(dep.minutes);
    // 4 + 1 + 11 + 1 + 4 = 21 chars
    format!("{:<4} {:<11} {}", line, dest, time)
}

/// Returns a right-aligned 4-char time field.
fn fmt_time(minutes: i32) -> String {
    match minutes {
        i32::MIN..=0 => "NOW ".to_string(),
        1..=99 => format!("{:>3}m", minutes), // "  2m", " 15m"
        _ => ">99m".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_single_stop() {
        let h = header("Bořislavka", 0, 1);
        assert_eq!(h.chars().count(), 21, "header: {:?}", h);
    }

    #[test]
    fn header_multi_stop() {
        let h = header("Bořislavka", 0, 2);
        assert_eq!(h.chars().count(), 21, "header: {:?}", h);
        assert!(h.ends_with("1/2"), "header: {:?}", h);
    }

    #[test]
    fn row_length() {
        let dep = crate::api::Departure {
            line: "22".into(),
            destination: "Bílá Hora".into(),
            minutes: 5,
        };
        let row = departure_row(&dep);
        assert_eq!(row.chars().count(), 21, "row: {:?}", row);
    }

    #[test]
    fn row_now() {
        let dep = crate::api::Departure {
            line: "A".into(),
            destination: "Depo Hostivař".into(),
            minutes: 0,
        };
        let row = departure_row(&dep);
        assert!(row.ends_with("NOW "), "row: {:?}", row);
        assert_eq!(row.chars().count(), 21);
    }

    #[test]
    fn fmt_time_cases() {
        assert_eq!(fmt_time(-5), "NOW ");
        assert_eq!(fmt_time(0), "NOW ");
        assert_eq!(fmt_time(1), "  1m");
        assert_eq!(fmt_time(99), " 99m");
        assert_eq!(fmt_time(100), ">99m");
    }
}
