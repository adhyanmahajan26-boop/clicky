//! Routine schedules: "daily 08:00", "weekdays 8:30", "weekly mon 09:00", "hourly", "hourly :15", "every 30 minutes", "every 2 hours".

use crate::model::{Schedule, ScheduleKind};
use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Timelike, Utc};
use regex::Regex;

pub fn parse(text: &str) -> Option<Schedule> {
    let lower = text.trim().to_lowercase();
    let numbers = |s: &str| -> Vec<u32> { s.split(|c: char| !c.is_ascii_digit()).filter_map(|x| x.parse().ok()).collect() };
    let time = |s: &str| -> Option<(u32, u32)> {
        let re = Regex::new(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?").unwrap();
        let m = re.captures(s)?;
        let mut hour: u32 = m[1].parse().ok()?;
        let minute: u32 = m.get(2).map(|x| x.as_str().parse().unwrap_or(0)).unwrap_or(0);
        match m.get(3).map(|x| x.as_str()) {
            Some("pm") if hour < 12 => hour += 12,
            Some("am") if hour == 12 => hour = 0,
            _ => {}
        }
        if hour > 23 || minute > 59 { None } else { Some((hour, minute)) }
    };
    let base = Schedule { kind: ScheduleKind::Daily, hour: 9, minute: 0, weekday: 2, interval_minutes: 60 };
    if lower.starts_with("every") {
        let amount = numbers(&lower).first().copied().unwrap_or(1);
        if lower.contains("hour") { return Some(Schedule { kind: ScheduleKind::Every, interval_minutes: amount * 60, ..base }); }
        if lower.contains("min") { return Some(Schedule { kind: ScheduleKind::Every, interval_minutes: amount, ..base }); }
        if lower.contains("weekday") { if let Some((h, m)) = time(&lower) { return Some(Schedule { kind: ScheduleKind::Weekdays, hour: h, minute: m, ..base }); } }
        if lower.contains("day") { if let Some((h, m)) = time(&lower) { return Some(Schedule { kind: ScheduleKind::Daily, hour: h, minute: m, ..base }); } }
    }
    if lower.starts_with("hourly") {
        let minute = numbers(&lower).first().copied().unwrap_or(0).min(59);
        return Some(Schedule { kind: ScheduleKind::Hourly, minute, ..base });
    }
    let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    if lower.starts_with("weekly") || days.iter().any(|d| lower.starts_with(d)) {
        let weekday = days.iter().position(|d| lower.contains(d)).unwrap_or(1) as u32 + 1;
        let (hour, minute) = time(&lower.replace("weekly", "")).unwrap_or((9, 0));
        return Some(Schedule { kind: ScheduleKind::Weekly, hour, minute, weekday, ..base });
    }
    if lower.starts_with("weekday") {
        let (hour, minute) = time(&lower)?;
        return Some(Schedule { kind: ScheduleKind::Weekdays, hour, minute, ..base });
    }
    if lower.starts_with("daily") || lower.starts_with("every day") {
        let (hour, minute) = time(&lower)?;
        return Some(Schedule { kind: ScheduleKind::Daily, hour, minute, ..base });
    }
    None
}

pub fn period_seconds(s: &Schedule) -> f64 {
    match s.kind {
        ScheduleKind::Every => (s.interval_minutes.max(5) * 60) as f64,
        ScheduleKind::Hourly => 3600.0,
        ScheduleKind::Daily | ScheduleKind::Weekdays => 86400.0,
        ScheduleKind::Weekly => 604800.0,
    }
}

pub fn label(s: &Schedule) -> String {
    let time = format!("{}:{:02}", s.hour, s.minute);
    match s.kind {
        ScheduleKind::Daily => format!("Every day at {time}"),
        ScheduleKind::Weekdays => format!("Weekdays at {time}"),
        ScheduleKind::Weekly => {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
            format!("Every {} at {time}", names[((s.weekday + 6) % 7) as usize])
        }
        ScheduleKind::Hourly => format!("Every hour at :{:02}", s.minute),
        ScheduleKind::Every => if s.interval_minutes % 60 == 0 { format!("Every {} h", s.interval_minutes / 60) } else { format!("Every {} min", s.interval_minutes) },
    }
}

/// The first run time after `date`, in the computer's own time zone.
pub fn next_after(s: &Schedule, date: DateTime<Utc>) -> DateTime<Utc> {
    match s.kind {
        ScheduleKind::Every => date + Duration::minutes(s.interval_minutes.max(5) as i64),
        ScheduleKind::Hourly => {
            let local = date.with_timezone(&Local);
            let candidate = local.with_minute(s.minute).and_then(|t| t.with_second(0)).and_then(|t| t.with_nanosecond(0)).unwrap_or(local);
            let candidate = candidate.with_timezone(&Utc);
            if candidate > date { candidate } else { candidate + Duration::hours(1) }
        }
        _ => {
            let local = date.with_timezone(&Local);
            let mut day = local.date_naive();
            for _ in 0..15 {
                if let Some(naive) = day.and_hms_opt(s.hour, s.minute, 0) {
                    if let Some(candidate) = Local.from_local_datetime(&naive).earliest() {
                        let candidate = candidate.with_timezone(&Utc);
                        if candidate > date {
                            // chrono: Monday = 1 … Sunday = 7; Theo's numbering: Sunday = 1 … Saturday = 7.
                            let weekday = naive.weekday().number_from_sunday();
                            let fits = match s.kind {
                                ScheduleKind::Daily => true,
                                ScheduleKind::Weekdays => (2..=6).contains(&weekday),
                                ScheduleKind::Weekly => weekday == s.weekday,
                                _ => true,
                            };
                            if fits { return candidate; }
                        }
                    }
                }
                day = day.succ_opt().unwrap_or(day);
            }
            date + Duration::days(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses() {
        assert_eq!(parse("daily 03:00").unwrap().hour, 3);
        assert_eq!(parse("every 30 minutes").unwrap().interval_minutes, 30);
        assert_eq!(parse("every 2 hours").unwrap().interval_minutes, 120);
        assert_eq!(parse("weekly mon 09:00").unwrap().weekday, 2);
        assert_eq!(parse("weekdays 8:30pm").unwrap().hour, 20);
        assert!(parse("whenever").is_none());
    }
    #[test]
    fn next_is_later() {
        let now = Utc::now();
        for text in ["daily 03:00", "weekdays 08:00", "weekly fri 10:00", "hourly :15", "every 30 minutes"] {
            let s = parse(text).unwrap();
            let next = next_after(&s, now);
            assert!(next > now, "{text}");
            assert!(next - now <= Duration::days(8));
        }
    }
}
