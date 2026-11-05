import 'dart:io';

/// Opens an exported file with the OS-default application
/// (Excel for .xlsx, Word for .docx, the PDF reader for .pdf) so the
/// user lands straight in the artifact they just saved.
///
/// Fire-and-forget: explorer.exe hands the file to the associated app
/// and may report a nonzero exit code even when it opened fine, so the
/// process result is deliberately not awaited.
Future<void> openExportedFile(String path) async {
  try {
    await Process.start('explorer', [path], mode: ProcessStartMode.detached);
  } catch (_) {
    // Launch is best-effort; the saved path is still shown in the
    // snackbar so the user can open the file manually.
  }
}
