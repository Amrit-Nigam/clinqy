//! Local date/times as the model writes them: "yyyy-MM-dd HH:mm", "yyyy-MM-dd" (all day), ISO 8601.

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone};

pub fn parse_local(s: &str) -> Option<DateTime<Local>> {
    let s = s.trim();
    if let Ok(d) = DateTime::parse_from_rfc3339(s) {
        return Some(d.with_timezone(&Local));
    }
    for f in ["%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"] {
        if let Ok(n) = NaiveDateTime::parse_from_str(s, f) {
            return Local.from_local_datetime(&n).single();
        }
    }
    NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().and_then(|d| Local.from_local_datetime(&d.and_hms_opt(0, 0, 0)?).single())
}

/// True when the string is a date with no time (an all-day event).
pub fn is_date_only(s: &str) -> bool {
    NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d").is_ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses() {
        assert!(super::parse_local("2026-10-02 15:00").is_some());
        assert!(super::parse_local("2026-10-02").is_some());
        assert!(super::is_date_only("2026-10-02"));
        assert!(super::parse_local("soon").is_none());
    }
}
