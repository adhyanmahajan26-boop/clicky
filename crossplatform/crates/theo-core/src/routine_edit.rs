//! Adding and editing a routine from the Routines page (the Mac's `RoutineEditor`): who runs it, what it does, when, and on
//! or off. The page is the owner's own hands, so nothing here asks again; a bot's ```routine block still goes through its card.

use crate::harness::Harness;
use crate::model::{Routine, Schedule, ScheduleKind};
use serde_json::{json, Value};

/// The editor's limits: every N minutes goes from 5 minutes to a day, as the Mac's stepper.
pub const SHORTEST_INTERVAL_MINUTES: u32 = 5;
pub const LONGEST_INTERVAL_MINUTES: u32 = 1440;
pub const LONGEST_INSTRUCTION: usize = 8000;
pub const LONGEST_NAME: usize = 80;

/// A schedule from the editor: `{kind, hour, minute, weekday, intervalMinutes}`, each checked, or the words a bot would write
/// ("weekdays 08:30").
pub fn schedule_from(value: &Value) -> Result<Schedule, String> {
    if let Some(words) = value.as_str() {
        return crate::schedule::parse(words).ok_or_else(|| "Vello can't read that time.".to_string());
    }
    let kind = match value.get("kind").and_then(|k| k.as_str()).unwrap_or("") {
        "daily" => ScheduleKind::Daily,
        "weekdays" => ScheduleKind::Weekdays,
        "weekly" => ScheduleKind::Weekly,
        "hourly" => ScheduleKind::Hourly,
        "every" => ScheduleKind::Every,
        _ => return Err("Pick when it runs.".into()),
    };
    let number = |key: &str, default: u32| value.get(key).and_then(|n| n.as_u64()).map(|n| n.min(u32::MAX as u64) as u32).unwrap_or(default);
    let hour = number("hour", 9);
    let minute = number("minute", 0);
    let weekday = number("weekday", 2);
    let interval_minutes = number("intervalMinutes", 60);
    if hour > 23 || minute > 59 { return Err("That isn't a time of day.".into()); }
    if !(1..=7).contains(&weekday) { return Err("Pick a day of the week.".into()); }
    if kind == ScheduleKind::Every && !(SHORTEST_INTERVAL_MINUTES..=LONGEST_INTERVAL_MINUTES).contains(&interval_minutes) {
        return Err(format!("Every N minutes goes from {SHORTEST_INTERVAL_MINUTES} minutes to a day ({LONGEST_INTERVAL_MINUTES})."));
    }
    Ok(Schedule { kind, hour, minute, weekday, interval_minutes })
}

/// A routine's name when the owner gave none: the start of what it does, as the Mac does.
pub fn name_or_instruction(name: &str, instruction: &str) -> String {
    let name = name.trim();
    if !name.is_empty() { return name.chars().take(LONGEST_NAME).collect(); }
    instruction.trim().chars().take(40).collect::<String>().trim().to_string()
}

/// `routineSave {id?, name, target, do, schedule, paused?}`: a new routine, or an edit of one. An edit keeps its runs, and its
/// next slot unless the schedule changed.
pub fn save(h: &Harness, cmd: &Value) -> Value {
    let text = |key: &str| cmd.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let instruction = text("do").map(|t| t.trim().to_string()).unwrap_or_default();
    if instruction.is_empty() { return crate::control::err("Say what it should do."); }
    if instruction.chars().count() > LONGEST_INSTRUCTION { return crate::control::err("That's too long for a routine."); }
    let target = text("target").unwrap_or_default();
    let target_ok = match target.strip_prefix("group:") {
        Some(group) => h.group(group).map(|g| g.head_id.is_some()).unwrap_or(false),
        None => h.bot(&target).is_some(),
    };
    if !target_ok { return crate::control::err("Pick who runs it."); }
    let schedule = match schedule_from(cmd.get("schedule").or_else(|| cmd.get("when")).unwrap_or(&Value::Null)) {
        Ok(schedule) => schedule,
        Err(problem) => return crate::control::err(&problem),
    };
    let name = name_or_instruction(&text("name").unwrap_or_default(), &instruction);
    let existing = text("id").and_then(|id| h.with(|s| s.routines.iter().find(|r| r.id == id).cloned()));
    let routine = match existing {
        Some(mut routine) => {
            routine.name = name;
            routine.target = target;
            routine.instruction = instruction;
            routine.schedule = schedule;
            if let Some(paused) = cmd.get("paused").and_then(|p| p.as_bool()) { routine.paused = paused; }
            routine
        }
        None => {
            if text("id").is_some() { return crate::control::err("That routine is gone."); }
            let mut routine = Routine::new(&name, &target, &instruction, schedule);
            routine.paused = cmd.get("paused").and_then(|p| p.as_bool()).unwrap_or(false);
            routine
        }
    };
    let id = routine.id.clone();
    let was_paused = h.with(|s| s.routines.iter().find(|r| r.id == id).map(|r| r.paused));
    let now_paused = routine.paused;
    h.save_routine(routine);
    // Turned back on from the editor: it picks up at the next slot, as Resume does.
    if was_paused == Some(true) && !now_paused { h.set_paused(false, &id); }
    let saved = h.with(|s| s.routines.iter().find(|r| r.id == id).cloned());
    match saved {
        Some(r) => crate::control::ok(json!({"id": r.id, "name": r.name, "label": crate::schedule::label(&r.schedule), "next": r.next_run_at.map(|d| d.to_rfc3339())})),
        None => crate::control::err("It couldn't be saved."),
    }
}

/// The list with each schedule in words, for the page.
pub fn list(h: &Harness) -> Value {
    let routines = h.with(|s| s.routines.clone());
    Value::Array(routines.iter().map(|r| {
        let mut value = serde_json::to_value(r).unwrap_or_default();
        value["label"] = crate::schedule::label(&r.schedule).into();
        value
    }).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_editors_schedule_is_checked() {
        let s = schedule_from(&json!({"kind": "weekly", "hour": 8, "minute": 30, "weekday": 6})).unwrap();
        assert_eq!((s.kind, s.hour, s.minute, s.weekday), (ScheduleKind::Weekly, 8, 30, 6));
        assert_eq!(crate::schedule::label(&s), "Every Friday at 8:30");
        assert_eq!(schedule_from(&json!({"kind": "every", "intervalMinutes": 45})).unwrap().interval_minutes, 45);
        assert!(schedule_from(&json!({"kind": "every", "intervalMinutes": 2})).is_err());
        assert!(schedule_from(&json!({"kind": "every", "intervalMinutes": 2000})).is_err());
        assert!(schedule_from(&json!({"kind": "daily", "hour": 24})).is_err());
        assert!(schedule_from(&json!({"kind": "weekly", "weekday": 0})).is_err());
        assert!(schedule_from(&json!({"kind": "sometimes"})).is_err());
        assert_eq!(schedule_from(&json!("weekdays 8:30")).unwrap().kind, ScheduleKind::Weekdays);
        assert!(schedule_from(&json!("whenever")).is_err());
    }

    #[test]
    fn a_routine_without_a_name_is_named_by_what_it_does() {
        assert_eq!(name_or_instruction("  ", "Sum up what needs a reply in my inbox and the team channel"), "Sum up what needs a reply in my inbox an");
        assert_eq!(name_or_instruction("Morning inbox", "x"), "Morning inbox");
    }
}
