/// Where a run stands for what may be done with it, as the core decided:
/// [live] from connecting to applying — the screen is held, leaving asks
/// first; [resumable] when an attempt ended short and a resume runs it
/// again; [over] when it finished or was stopped.
enum RunStanding { live, resumable, over }
