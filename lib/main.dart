import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:record/record.dart'; // Import for audio recording
import 'package:whisper_flutter_new/whisper_flutter_new.dart'; // Import for Whisper transcription
import 'package:path_provider/path_provider.dart'; // Import for getting temporary file paths
import 'dart:io'; // Required for File operations
import 'dart:typed_data'; // NEW: For ByteData and Endian
import 'package:path/path.dart' as p; // NEW: For path manipulation

// Define your Picovoice AccessKey here.
const String PICOVOICE_ACCESS_KEY = "X1GqPI5LzGsqY+9wtxNX0UaRBpv050tnDet5bOGKbwKNmi1RJ7bImQ==";

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _statusText = 'Initializing...';
  bool _isListening = false;
  bool _wakeWordDetected = false;
  String _transcriptionResult = '';
  bool _isTranscribing = false;

  late PorcupineManager _porcupineManager;
  final AudioRecorder _audioRecorder = AudioRecorder(); // Initialize AudioRecorder
  late Whisper _whisper; // Declare Whisper instance

  @override
  void initState() {
    super.initState();
    _requestMicPermission();
    _initWhisper(); // Initialize Whisper model
  }

  // --- Whisper Initialization ---
  void _initWhisper() async {
    try {
      // Initialize Whisper with the required 'model' parameter.
      // Ensure this matches the .bin file you've placed in assets/models/
      // For example, if you downloaded ggml-base.en.bin, use WhisperModel.base.
      _whisper = Whisper(
        model: WhisperModel.base, // Using .base as per our last discussion
      );
      print('Whisper instance initialized with model: ${WhisperModel.base}');
    } catch (e) {
      print('🚨 Error initializing Whisper: $e');
      setState(() {
        _statusText = 'Error initializing Whisper: $e';
      });
    }
  }

  // --- Permission Handling ---
  void _requestMicPermission() async {
    setState(() {
      _statusText = 'Requesting Microphone Permission...';
    });
    var status = await Permission.microphone.request();
    if (status.isGranted) {
      print('Mic permission granted. Attempting to start wake word detection.');
      setState(() {
        _statusText = 'Mic permission granted. Initializing Porcupine...';
      });
      _startWakeWordDetection();
    } else {
      print('Mic permission denied. Cannot start wake word detection.');
      setState(() {
        _statusText = 'Mic permission denied. App cannot function.';
        _isListening = false;
      });
    }
  }

  // --- Porcupine Wake Word Detection ---
  void _wakeWordCallback(int keywordIndex) async {
    print('🟢 Bumblebee wake word detected! Keyword Index: $keywordIndex');
    setState(() {
      _wakeWordDetected = true;
      _statusText = 'Bumblebee detected! Recording for 10 seconds...';
    });

    // Stop Porcupine listening temporarily to record audio
    if (_isListening) {
      await _porcupineManager.stop();
      setState(() {
        _isListening = false;
      });
    }

    // Start recording audio for transcription
    try {
      if (await _audioRecorder.hasPermission()) {
        // We will record to a .wav file, but it will be raw PCM initially.
        final String? audioFilePath = await _getFilePath('audio_clip.wav');
        
        // Ensure audioFilePath is not null before starting recording
        if (audioFilePath == null) {
          print('Error: Could not get a valid audio file path.');
          setState(() {
            _statusText = 'Error getting audio file path.';
            _isTranscribing = false;
          });
          // Restart Porcupine if recording couldn't start
          if (mounted) {
            await _porcupineManager.start();
            setState(() {
              _isListening = true;
              _wakeWordDetected = false;
              _statusText = 'Listening for "Bumblebee"...';
            });
          }
          return; // Exit the function
        }

        // Use pcm16bits encoder to get raw 16-bit PCM data
        const config = RecordConfig(
          encoder: AudioEncoder.pcm16bits, // Crucial: Use pcm16bits
          numChannels: 1,
          sampleRate: 16000,
        );

        await _audioRecorder.start(config, path: audioFilePath);

        print('Recording started to: $audioFilePath (raw PCM)');
        print('DEBUG: Starting transcription for audio: $audioFilePath');

        // Record for 10 seconds
        await Future.delayed(const Duration(seconds: 10));

        final String? recordedPath = await _audioRecorder.stop();
        if (recordedPath != null) {
          print('Raw PCM recording stopped. File: $recordedPath');
          setState(() {
            _statusText = 'Recording complete. Preparing file for transcription...';
            _isTranscribing = true;
          });

          // NEW: Convert the raw PCM file to a proper WAV file with header
          final String wavFilePath = await _createWavFile(recordedPath);
          print('DEBUG: Created WAV file with header at: $wavFilePath');

          // Transcribe the new WAV file
          await _transcribeAudio(wavFilePath);

          // Clean up the original raw PCM file
          await File(recordedPath).delete();
          print('DEBUG: Deleted original raw PCM file: $recordedPath');

        } else {
          print('Error: Could not get recorded audio path.');
          setState(() {
            _statusText = 'Error recording audio.';
            _isTranscribing = false;
          });
        }
      } else {
        print('Audio recording permission not granted.');
        setState(() {
          _statusText = 'Audio recording permission denied.';
        });
      }
    } catch (e) {
      print('Error during audio recording: $e');
      setState(() {
        _statusText = 'Error during recording: $e';
        _isTranscribing = false;
      });
    } finally {
      // Restart Porcupine listening after transcription is done
      if (mounted) {
        await _porcupineManager.start();
        print('🎙️ Listening for wake word...');
        setState(() {
          _isListening = true;
          _wakeWordDetected = false; // Reset wake word visual
          _statusText = 'Listening for "Bumblebee"...';
          _isTranscribing = false; // Reset transcription status
        });
      }
    }
  }

  void _errorCallback(PorcupineException error) {
    print('🚨 Porcupine Error: ${error.message}');
    setState(() {
      _statusText = 'Error: ${error.message}';
      _isListening = false; // Stop listening on error
    });
  }

  void _startWakeWordDetection() async {
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        PICOVOICE_ACCESS_KEY,
        ['assets/keywords/Bumblebee_en_android_v3_0_0.ppn'],
        _wakeWordCallback,
        modelPath: 'assets/models/porcupine_params.pv',
        sensitivities: [0.75],
        errorCallback: _errorCallback,
      );

      await _porcupineManager.start();
      print('🎙️ Listening for wake word...');
      setState(() {
        _isListening = true;
        _statusText = 'Listening for "Bumblebee"...';
      });
    } on PorcupineException catch (err) {
      _errorCallback(err);
    } catch (e) {
      print('An unexpected error occurred during Porcupine initialization: $e');
      setState(() {
        _statusText = 'Initialization Error: $e';
        _isListening = false;
      });
    }
  }

  void _stopWakeWordDetection() async {
    if (_isListening) {
      await _porcupineManager.stop();
      print('🛑 Stopped listening.');
      setState(() {
        _isListening = false;
        _statusText = 'Stopped listening.';
      });
    }
  }

  // Helper to get a temporary file path for audio recording
  Future<String> _getFilePath(String filename) async {
    final dir = await getTemporaryDirectory();
    return p.join(dir.path, filename); // Use p.join for platform-independent paths
  }

  /// NEW HELPER FUNCTION: Creates a valid WAV file from raw PCM data.
  Future<String> _createWavFile(String pcmPath) async {
    final pcmData = await File(pcmPath).readAsBytes();
    final pcmDataLength = pcmData.length;
    
    // Every WAV file needs a 44-byte header.
    final header = ByteData(44);
    final buffer = header.buffer.asUint8List();

    // RIFF identifier
    buffer.setRange(0, 4, 'RIFF'.codeUnits);
    // Total file size - 8 bytes
    header.setUint32(4, pcmDataLength + 36, Endian.little);
    // WAVE identifier
    buffer.setRange(8, 12, 'WAVE'.codeUnits);
    // "fmt " chunk identifier
    buffer.setRange(12, 16, 'fmt '.codeUnits);
    // Sub-chunk size (16 for PCM)
    header.setUint32(16, 16, Endian.little);
    // Audio format (1 for PCM)
    header.setUint16(20, 1, Endian.little);
    // Number of channels (1 for mono)
    header.setUint16(22, 1, Endian.little);
    // Sample rate (16000)
    header.setUint32(24, 16000, Endian.little);
    // Byte rate (SampleRate * NumChannels * BitsPerSample/8)
    header.setUint32(28, 16000 * 1 * 2, Endian.little); // 16000 * 1 channel * 2 bytes/sample (16 bits)
    // Block align (NumChannels * BitsPerSample/8)
    header.setUint16(32, 2, Endian.little); // 1 channel * 2 bytes/sample
    // Bits per sample (16)
    header.setUint16(34, 16, Endian.little);
    // "data" chunk identifier
    buffer.setRange(36, 40, 'data'.codeUnits);
    // Data size
    header.setUint32(40, pcmDataLength, Endian.little);

    // Create the new WAV file path
    final directory = await getTemporaryDirectory();
    final wavPath = p.join(directory.path, 'audio_clip_final.wav');
    final wavFile = File(wavPath);

    // Write the header and the PCM data to the new file
    await wavFile.writeAsBytes(buffer, mode: FileMode.write);
    await wavFile.writeAsBytes(pcmData, mode: FileMode.append);

    print('Created WAV file with header at: $wavPath');
    return wavPath;
  }

  // --- Whisper Transcription ---
  Future<void> _transcribeAudio(String audioPath) async {
    print('DEBUG: Calling _whisper.transcribe for file: $audioPath...');
    try {
      final transcription = await _whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioPath,
          // language: 'en', // Uncomment and set if you want to specify language
          // isTranslate: false, // Uncomment and set to true for translation
          // isNoTimestamps: true, // Uncomment for full text without timestamps
        ),
      );
      print('DEBUG: _whisper.transcribe call completed.');

      if (transcription != null && transcription.text != null) {
        print('✅ Transcription: ${transcription.text}');
        setState(() {
          _transcriptionResult = transcription.text!;
          _statusText = 'Transcription: "${transcription.text!}"';
        });
      } else {
        print('No transcription result.');
        setState(() {
          _transcriptionResult = 'No transcription available.';
          _statusText = 'No transcription available.';
        });
      }
    } catch (e) {
      print('🚨 Error during transcription: $e');
      setState(() {
        _transcriptionResult = 'Transcription Error: $e';
        _statusText = 'Transcription Error: $e';
      });
    } finally {
      // Clean up the recorded audio file if needed
      final file = File(audioPath);
      if (await file.exists()) {
        await file.delete();
        print('Deleted temporary audio file: $audioPath');
      }
      setState(() {
        _isTranscribing = false;
      });
      print('DEBUG: Transcription process finished (finally block).');
    }
  }

  @override
  void dispose() {
    _porcupineManager.delete(); // Release native Porcupine resources
    _audioRecorder.dispose(); // Dispose the audio recorder
    // _whisper.dispose(); // REMOVED: This method is not defined for Whisper
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bumblebee Wake Word',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter', // Using Inter font
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Bumblebee Listener & Transcriber'),
          backgroundColor: Colors.blueAccent,
          centerTitle: true,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Say "Bumblebee"...',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: _wakeWordDetected ? Colors.green.shade800 : Colors.black87,
                  ),
                ),
                const SizedBox(height: 20),
                Icon(
                  _isListening ? Icons.mic : Icons.mic_off,
                  size: 80,
                  color: _isListening
                      ? (_wakeWordDetected ? Colors.green : Colors.blueAccent)
                      : Colors.redAccent,
                ),
                const SizedBox(height: 20),
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    color: _wakeWordDetected
                        ? Colors.green.shade700
                        : _isTranscribing
                            ? Colors.blue.shade700
                            : Colors.grey.shade700,
                    fontStyle: _isTranscribing ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
                const SizedBox(height: 20),
                if (_transcriptionResult.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    elevation: 5,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Last Transcription:',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _transcriptionResult,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 18, fontStyle: FontStyle.italic, color: Colors.deepPurple),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 40),
                ElevatedButton(
                  onPressed: _isTranscribing ? null : (_isListening ? _stopWakeWordDetection : _startWakeWordDetection),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isTranscribing
                        ? Colors.grey
                        : (_isListening ? Colors.redAccent : Colors.green),
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                    textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    elevation: 8,
                    shadowColor: Colors.black.withOpacity(0.4),
                  ),
                  child: Text(_isTranscribing
                      ? 'Transcribing...'
                      : (_isListening ? 'Stop Listening' : 'Start Listening')),
                ),
                const SizedBox(height: 10),
                if (!_isListening && _statusText.contains('Error'))
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text(
                      'Check console for detailed error messages (e.g., AccessKey, missing files).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.red, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
