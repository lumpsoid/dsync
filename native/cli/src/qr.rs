//! A pairing payload drawn as a QR symbol in a terminal, for `dsync pair
//! show` (SPEC §4.4). The encoder is the `qrcode` crate: Reed-Solomon
//! exists so a symbol keeps scanning despite a wrong module, which makes a
//! hand-rolled encoder's bugs silent. The drawing is ours, and total: a
//! grid maps to exactly one string.

use qrcode::types::QrError;
use qrcode::{Color, EcLevel, QrCode};

/// Low error correction keeps a ~500-character payload at a symbol that
/// fits an 80-column terminal; a symbol read once off a clean screen does
/// not need the damage tolerance of the higher levels (`qrencode`'s
/// default for the same reason).
pub const TERMINAL_EC_LEVEL: EcLevel = EcLevel::L;

/// The quiet zone ISO/IEC 18004 requires on every side.
const QUIET_ZONE: usize = 4;

/// `payload` as a symbol at [`TERMINAL_EC_LEVEL`], drawn by
/// [`render_modules`]. Fails only for a payload no QR version holds.
pub fn render_pairing_qr(payload: &str) -> Result<String, QrError> {
    let code = QrCode::with_error_correction_level(payload, TERMINAL_EC_LEVEL)?;
    let width = code.width();
    let colors = code.to_colors();
    Ok(render_modules(width, |row, col| {
        colors[row * width + col] == Color::Dark
    }))
}

/// Draws a `count`-by-`count` module grid, padded by the quiet zone, two
/// module rows per line with the half blocks: both light ` `, top dark
/// `▀`, bottom dark `▄`, both dark `█`. No colour escapes: the terminal's
/// own foreground draws dark. A row past the grid is light.
pub fn render_modules(count: usize, is_dark: impl Fn(usize, usize) -> bool) -> String {
    let size = count + QUIET_ZONE * 2;
    let dark = |row: usize, col: usize| {
        let (Some(r), Some(c)) = (row.checked_sub(QUIET_ZONE), col.checked_sub(QUIET_ZONE)) else {
            return false;
        };
        r < count && c < count && is_dark(r, c)
    };
    (0..size)
        .step_by(2)
        .map(|row| {
            (0..size)
                .map(|col| match (dark(row, col), dark(row + 1, col)) {
                    (false, false) => ' ',
                    (true, false) => '▀',
                    (false, true) => '▄',
                    (true, true) => '█',
                })
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Whether a terminal can be assumed to draw the half blocks: a real
/// terminal whose `TERM` is set and not `dumb` - the `isatty && TERM !=
/// dumb` stand-in coreutils, git and cargo use. A plain Windows console
/// sets no `TERM` and gets the fallback: a capable terminal missing the
/// symbol costs less than an incapable one printing mojibake.
pub fn terminal_supported(has_terminal: bool, term: Option<&str>) -> bool {
    has_terminal && term.is_some_and(|term| !term.is_empty() && term != "dumb")
}

#[cfg(test)]
mod tests {
    //! Every case of `test/cli/output/qr_terminal_renderer_test.dart`.

    use qrcode::Version;

    use super::*;

    const SAMPLE: &str = "dsync-pair:v1:AAECAwQFBgcICQ==";

    fn lines(rendered: &str) -> Vec<&str> {
        rendered.split('\n').collect()
    }

    fn encode(text: &str, level: EcLevel) -> QrCode {
        QrCode::with_error_correction_level(text, level).unwrap()
    }

    fn dark(code: &QrCode, row: usize, col: usize) -> bool {
        code[(col, row)] == Color::Dark
    }

    #[test]
    fn a_single_dark_module_sits_inside_the_quiet_zone() {
        let rendered = render_modules(1, |row, col| row == 0 && col == 0);
        let lines = lines(&rendered);
        assert_eq!(lines.len(), 5);
        assert!(lines.iter().all(|line| line.chars().count() == 9));
        assert_eq!(
            lines,
            [
                "         ",
                "         ",
                "    ▀    ",
                "         ",
                "         "
            ]
        );
    }

    #[test]
    fn an_all_light_grid_renders_as_blank_lines() {
        let rendered = render_modules(1, |_, _| false);
        assert!(lines(&rendered).iter().all(|line| *line == "         "));
    }

    #[test]
    fn a_diagonal_2x2_grid_draws_the_two_half_blocks() {
        let rendered = render_modules(2, |row, col| (row, col) == (0, 1) || (row, col) == (1, 0));
        let lines = lines(&rendered);
        assert_eq!(lines.len(), 5);
        assert_eq!(lines[1], "          ");
        assert_eq!(lines[2], "    ▄▀    ");
        assert_eq!(lines[3], "          ");
    }

    #[test]
    fn two_dark_rows_draw_a_full_block() {
        assert_eq!(lines(&render_modules(2, |_, _| true))[2], "    ██    ");
    }

    #[test]
    fn an_even_module_count_still_pads_to_an_exact_grid() {
        let rendered = render_modules(6, |_, _| false);
        let lines = lines(&rendered);
        assert_eq!(lines.len(), 7);
        assert!(lines.iter().all(|line| line.chars().count() == 14));
    }

    #[test]
    fn the_width_follows_the_version_formula() {
        let code = encode(SAMPLE, TERMINAL_EC_LEVEL);
        let Version::Normal(version) = code.version() else {
            panic!("a micro symbol");
        };
        assert_eq!(code.width(), usize::try_from(version).unwrap() * 4 + 17);
    }

    #[test]
    fn all_three_finder_patterns_have_the_fixed_shape() {
        let code = encode(SAMPLE, TERMINAL_EC_LEVEL);
        let n = code.width();
        for (top, left) in [(0, 0), (0, n - 7), (n - 7, 0)] {
            for r in 0..7 {
                for c in 0..7 {
                    let ring = r == 0 || r == 6 || c == 0 || c == 6;
                    let centre = (2..=4).contains(&r) && (2..=4).contains(&c);
                    assert_eq!(
                        dark(&code, top + r, left + c),
                        ring || centre,
                        "finder at ({top},{left}), offset ({r},{c})"
                    );
                }
            }
        }
    }

    #[test]
    fn stronger_error_correction_never_shrinks_the_symbol() {
        let widths: Vec<_> = [EcLevel::L, EcLevel::M, EcLevel::Q, EcLevel::H]
            .into_iter()
            .map(|level| encode(SAMPLE, level).width())
            .collect();
        assert!(
            widths.windows(2).all(|pair| pair[0] <= pair[1]),
            "{widths:?}"
        );
    }

    #[test]
    fn different_payloads_give_different_symbols() {
        let short = encode("dsync-pair:v1:AAAA", TERMINAL_EC_LEVEL);
        let long = encode(
            "dsync-pair:v1:ZZZZZZZZZZZZZZZZZZZZZZZZZZZZ",
            TERMINAL_EC_LEVEL,
        );
        assert_ne!(short.width(), long.width());
    }

    #[test]
    fn the_pairing_qr_is_exactly_the_modules_drawn() {
        let code = encode(SAMPLE, TERMINAL_EC_LEVEL);
        let direct = render_modules(code.width(), |row, col| dark(&code, row, col));
        assert_eq!(render_pairing_qr(SAMPLE).unwrap(), direct);
    }

    #[test]
    fn the_quiet_zone_is_blank_around_a_real_symbol() {
        let rendered = render_pairing_qr(SAMPLE).unwrap();
        let lines = lines(&rendered);
        assert!(lines[0].chars().all(|c| c == ' '));
        assert!(lines[lines.len() - 1].chars().all(|c| c == ' '));
        for line in &lines {
            let chars: Vec<char> = line.chars().collect();
            assert_eq!(chars[..4], [' '; 4]);
            assert_eq!(chars[chars.len() - 4..], [' '; 4]);
        }
        assert!(rendered.contains('█'), "no symbol drawn");
    }

    #[test]
    fn a_payload_no_version_holds_is_an_error() {
        assert_eq!(
            render_pairing_qr(&"x".repeat(4000)),
            Err(QrError::DataTooLong)
        );
    }

    #[test]
    fn no_terminal_means_no_symbol() {
        assert!(!terminal_supported(false, Some("xterm-256color")));
    }

    #[test]
    fn an_unset_term_means_no_symbol() {
        assert!(!terminal_supported(true, None));
    }

    #[test]
    fn an_empty_term_means_no_symbol() {
        assert!(!terminal_supported(true, Some("")));
    }

    #[test]
    fn a_dumb_term_means_no_symbol() {
        assert!(!terminal_supported(true, Some("dumb")));
    }

    #[test]
    fn a_real_terminal_with_an_ordinary_term_gets_the_symbol() {
        assert!(terminal_supported(true, Some("xterm-256color")));
    }
}
