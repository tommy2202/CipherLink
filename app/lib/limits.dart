class ZipExtractionLimits {
  const ZipExtractionLimits({
    this.maxEntries = zipMaxEntriesDefault,
    this.maxTotalUncompressedBytes = zipMaxTotalUncompressedBytesDefault,
    this.maxSingleFileBytes = zipMaxSingleFileBytesDefault,
    this.maxPathLength = zipMaxPathLengthDefault,
  });

  final int maxEntries;
  final int maxTotalUncompressedBytes;
  final int maxSingleFileBytes;
  final int maxPathLength;
}

const int zipMaxEntriesDefault = 10000;
const int zipMaxTotalUncompressedBytesDefault = 512 * 1024 * 1024;
const int zipMaxSingleFileBytesDefault = 512 * 1024 * 1024;
const int zipMaxPathLengthDefault = 240;
