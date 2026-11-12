// Fork (mandeep/photos): "Back up photos from" date filter (pure helpers, unit tested).

/// Whether an asset created at [createdAt] passes the filter [fromMs] (ms since epoch; 0 = no filter).
bool passesBackupDateFilter(DateTime createdAt, int fromMs) {
  if (fromMs <= 0) {
    return true;
  }
  return createdAt.millisecondsSinceEpoch >= fromMs;
}
