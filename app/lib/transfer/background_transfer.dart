import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String backgroundDownloadGroup = 'ciphertext-downloads';
const String notificationDetailsPreferenceKey =
    'showNotificationDetailsInNotifications';

const String _runningTitle = 'Receiving transfer...';
const String _runningBody = 'Download in progress';
const String _completeTitle = 'Download complete';
const String _completeBody = 'Download complete';
const String _errorTitle = 'Receiving transfer...';
const String _errorBody = 'Download paused';

typedef BackgroundProgressCallback = void Function(
  BackgroundTransferUpdate update,
);

class BackgroundTransferUpdate {
  const BackgroundTransferUpdate(this.update);

  final TaskUpdate update;

  String get taskId => update.task.taskId;

  TaskStatusUpdate? get statusUpdate =>
      update is TaskStatusUpdate ? update as TaskStatusUpdate : null;

  TaskProgressUpdate? get progressUpdate =>
      update is TaskProgressUpdate ? update as TaskProgressUpdate : null;
}

class BackgroundTaskStatus {
  const BackgroundTaskStatus({
    required this.task,
    required this.status,
    required this.progress,
    required this.expectedFileSize,
  });

  final Task task;
  final TaskStatus status;
  final double progress;
  final int expectedFileSize;
}

class TransferTask {
  TransferTask({
    required this.taskId,
    required this.url,
    required this.headers,
    required this.filename,
    required this.directory,
    this.baseDirectory = BaseDirectory.applicationSupport,
    this.displayName,
    this.showNotificationDetails = false,
  });

  final String taskId;
  final String url;
  final Map<String, String> headers;
  final String filename;
  final String directory;
  final BaseDirectory baseDirectory;
  final String? displayName;
  final bool showNotificationDetails;

  DownloadTask toDownloadTask() {
    return DownloadTask(
      taskId: taskId,
      url: url,
      headers: headers,
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      updates: Updates.statusAndProgress,
      allowPause: true,
      group: backgroundDownloadGroup,
      displayName: displayName,
    );
  }
}

abstract class BackgroundTransferApi {
  Future<bool> enqueueBackgroundDownload(TransferTask task);
  Future<BackgroundTaskStatus?> queryBackgroundStatus(String taskId);
  Future<bool> cancelBackgroundTask(String taskId);
  void onBackgroundProgress(BackgroundProgressCallback callback);
}

class BackgroundTransferApiImpl implements BackgroundTransferApi {
  @override
  Future<bool> enqueueBackgroundDownload(TransferTask task) {
    return enqueueBackgroundDownload(task);
  }

  @override
  Future<BackgroundTaskStatus?> queryBackgroundStatus(String taskId) {
    return queryBackgroundStatus(taskId);
  }

  @override
  Future<bool> cancelBackgroundTask(String taskId) {
    return cancelBackgroundTask(taskId);
  }

  @override
  void onBackgroundProgress(BackgroundProgressCallback callback) {
    onBackgroundProgress(callback);
  }
}

final List<BackgroundProgressCallback> _callbacks = [];
bool _callbacksRegistered = false;
bool _initialized = false;

Future<void> initializeBackgroundTransfers({
  int? runInForegroundIfFileLargerThanMb,
}) async {
  if (_initialized) {
    return;
  }
  _initialized = true;
  await FileDownloader().ready;
  if (runInForegroundIfFileLargerThanMb != null) {
    await FileDownloader().configure(
      androidConfig: (
        Config.runInForegroundIfFileLargerThan,
        runInForegroundIfFileLargerThanMb
      ),
    );
  }
  _registerCallbacks();
  await FileDownloader().start();
}

Future<bool> enqueueBackgroundDownload(TransferTask task) async {
  await _ensureInitialized();
  final downloadTask = task.toDownloadTask();
  _configureNotifications(downloadTask, task.showNotificationDetails);
  return FileDownloader().enqueue(downloadTask);
}

Future<BackgroundTaskStatus?> queryBackgroundStatus(String taskId) async {
  await _ensureInitialized();
  final record = await FileDownloader().database.recordForId(taskId);
  if (record == null) {
    return null;
  }
  return BackgroundTaskStatus(
    task: record.task,
    status: record.status,
    progress: record.progress,
    expectedFileSize: record.expectedFileSize,
  );
}

Future<bool> cancelBackgroundTask(String taskId) async {
  await _ensureInitialized();
  return FileDownloader().cancelTaskWithId(taskId);
}

void onBackgroundProgress(BackgroundProgressCallback callback) {
  _callbacks.add(callback);
  _registerCallbacks();
}

Future<bool> loadNotificationDetailsPreference({
  SharedPreferences? prefs,
}) async {
  final storage = prefs ?? await SharedPreferences.getInstance();
  return storage.getBool(notificationDetailsPreferenceKey) ?? false;
}

Future<void> saveNotificationDetailsPreference(
  bool value, {
  SharedPreferences? prefs,
}) async {
  final storage = prefs ?? await SharedPreferences.getInstance();
  await storage.setBool(notificationDetailsPreferenceKey, value);
}

Future<void> _ensureInitialized() async {
  if (_initialized) {
    return;
  }
  await initializeBackgroundTransfers();
}

void _registerCallbacks() {
  if (_callbacksRegistered) {
    return;
  }
  _callbacksRegistered = true;
  FileDownloader().registerCallbacks(
    group: backgroundDownloadGroup,
    taskStatusCallback: (update) => _emitUpdate(BackgroundTransferUpdate(update)),
    taskProgressCallback: (update) =>
        _emitUpdate(BackgroundTransferUpdate(update)),
  );
}

void _emitUpdate(BackgroundTransferUpdate update) {
  for (final callback in List<BackgroundProgressCallback>.from(_callbacks)) {
    callback(update);
  }
}

void _configureNotifications(DownloadTask task, bool showDetails) {
  final display = task.displayName?.trim() ?? '';
  final runningBody = showDetails && display.isNotEmpty
      ? 'Download in progress: $display'
      : _runningBody;
  final completeBody = showDetails && display.isNotEmpty
      ? 'Download complete: $display'
      : _completeBody;
  FileDownloader().configureNotificationForTask(
    task,
    running: TaskNotification(_runningTitle, runningBody),
    complete: TaskNotification(_completeTitle, completeBody),
    error: const TaskNotification(_errorTitle, _errorBody),
    paused: const TaskNotification(_errorTitle, _errorBody),
    progressBar: true,
    tapOpensFile: false,
  );
}
