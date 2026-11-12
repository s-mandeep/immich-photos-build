// Fork (mandeep/photos): sizes the batch of uploads handed to the iOS background URLSession.
//
// Each queued upload keeps two temporary copies on the phone until it finishes: the file exported
// from Photos and the multipart body background_downloader builds from it. A batch is therefore
// bounded by file count, by total bytes, and by the share of free storage those copies may take.

/// Most files queued with the URLSession at once.
const int kUploadBatchMaxFiles = 300;

/// Most bytes (original file sizes) queued with the URLSession at once: 2 GB.
const int kUploadBatchMaxBytes = 2 * 1024 * 1024 * 1024;

/// Share of the phone's free storage the temporary copies of a batch may use.
const double kUploadBatchMaxFreeShare = 0.25;

/// Temporary copies kept per queued file (exported original + multipart body).
const int kUploadTempCopiesPerFile = 2;

/// Running budget for one batch. Seed it with what the session already holds, then offer each new
/// file in order; stop at the first file that does not fit so the queue keeps the library order.
class UploadBatchBudget {
  final int maxFiles;
  final int maxBytes;

  /// Bytes of free storage measured before the batch was built, or null if unknown.
  final int? freeBytes;
  final double maxFreeShare;

  int _files;
  int _bytes;
  int _newTempBytes = 0;

  UploadBatchBudget({
    this.freeBytes,
    int queuedFiles = 0,
    int queuedBytes = 0,
    this.maxFiles = kUploadBatchMaxFiles,
    this.maxBytes = kUploadBatchMaxBytes,
    this.maxFreeShare = kUploadBatchMaxFreeShare,
  }) : _files = queuedFiles,
       _bytes = queuedBytes;

  int get files => _files;
  int get bytes => _bytes;

  /// Storage the new files' temporary copies may still take. Already-queued files took their space
  /// before [freeBytes] was measured, so only new files count against it.
  int? get _tempAllowance => freeBytes == null ? null : (freeBytes! * maxFreeShare).floor();

  /// True when no further file can be added.
  bool get isFull => _files >= maxFiles || _bytes >= maxBytes || (_tempAllowance != null && _tempAllowance! <= 0);

  /// Whether a file of [size] bytes fits. A single file larger than [maxBytes] may go alone into an
  /// otherwise empty batch, provided its temporary copies fit the free-storage allowance.
  bool fits(int size) {
    if (size < 0 || _files >= maxFiles) {
      return false;
    }
    final allowance = _tempAllowance;
    if (allowance != null && _newTempBytes + size * kUploadTempCopiesPerFile > allowance) {
      return false;
    }
    if (_bytes + size > maxBytes) {
      return _files == 0;
    }
    return true;
  }

  /// Offer a file: adds it and returns true if it fits, otherwise leaves the budget unchanged.
  bool tryAdd(int size) {
    if (!fits(size)) {
      return false;
    }
    _files++;
    _bytes += size;
    _newTempBytes += size * kUploadTempCopiesPerFile;
    return true;
  }
}
