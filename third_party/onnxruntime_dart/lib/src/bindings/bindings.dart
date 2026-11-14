import 'dart:ffi';
import 'dart:io';
import 'package:onnxruntime_dart/src/bindings/onnxruntime_bindings_generated.dart';

/// Optional explicit path of the ONNX Runtime shared library. Must be set
/// before the first ONNX Runtime call in the isolate (chesster patch).
String? onnxRuntimeLibraryPath;

final DynamicLibrary _dylib = () {
  final explicitPath = onnxRuntimeLibraryPath;
  if (explicitPath != null) {
    return DynamicLibrary.open(explicitPath);
  }

  if (Platform.isAndroid) {
    return DynamicLibrary.open('libonnxruntime.so');
  }

  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }

  if (Platform.isMacOS) {
    return DynamicLibrary.open('libonnxruntime.1.15.1.dylib');
  }

  if (Platform.isWindows) {
    return DynamicLibrary.open('onnxruntime.dll');
  }

  if (Platform.isLinux) {
    return DynamicLibrary.open('libonnxruntime.so.1.15.1');
  }

  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// OnnxRuntime Bindings
final onnxRuntimeBinding = OnnxRuntimeBindings(_dylib);
