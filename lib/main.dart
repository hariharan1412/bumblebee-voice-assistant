import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';

// Define your Picovoice AccessKey here.
const String PICOVOICE_ACCESS_KEY = "X1GqPI5LzGsqY+9wtxNX0UaRBpv050tnDet5bOGKbwKNmi1RJ7bImQ==";

void main() {
  runApp(const MyApp()); // Added const
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key); // Added const constructor

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _statusText = 'Initializing...';
  bool _isListening = false;
  bool _wakeWordDetected = false;
  late PorcupineManager _porcupineManager;

  @override
  void initState() {
    super.initState();
    // Request mic permission and start detection when the widget initializes
    _requestMicPermission();
  }

  // Define the wake word callback function
  void _wakeWordCallback(int keywordIndex) {
    // This function is called when a wake word is detected.
    // The keywordIndex tells you which wake word was detected if you have multiple.
    print('🟢 Bumblebee wake word detected! Keyword Index: $keywordIndex');
    setState(() {
      _wakeWordDetected = true;
      _statusText = 'Bumblebee detected! 🐝';
    });

    // Optionally reset the visual feedback after a short delay
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _wakeWordDetected = false;
          _statusText = _isListening ? 'Listening for wake word...' : 'Tap to start listening';
        });
      }
    });
  }

  // Define the error callback function
  void _errorCallback(PorcupineException error) {
    print('🚨 Porcupine Error: ${error.message}');
    setState(() {
      _statusText = 'Error: ${error.message}';
      _isListening = false; // Stop listening on error
    });
  }

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

  void _startWakeWordDetection() async {
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        PICOVOICE_ACCESS_KEY,
        ['assets/keywords/Bumblebee_en_android_v3_0_0.ppn'],
        _wakeWordCallback,
        modelPath: 'assets/models/porcupine_params.pv', // Path to your .pv model file
        sensitivities: [0.75], // You can adjust this from 0.0 to 1.0 (default is 0.5)
        errorCallback: _errorCallback, // Pass the error callback
      );

      await _porcupineManager.start();
      print('🎙️ Listening for wake word...');
      setState(() {
        _isListening = true;
        _statusText = 'Listening for "Bumblebee"...';
      });
    } on PorcupineException catch (err) {
      _errorCallback(err); // Use the error callback for Porcupine-specific errors
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
    // No need to dispose here if you might restart later, but generally
    // you would dispose the manager in the dispose() method of the StatefulWidget.
  }

  @override
  void dispose() {
    _porcupineManager.delete(); // Release native resources
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bumblebee Wake Word',
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Bumblebee Listener'),
          backgroundColor: Colors.blueAccent,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Say "Bumblebee"...',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: _wakeWordDetected ? Colors.green : Colors.black, // Color changes on detection
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _statusText,
                style: TextStyle(
                  fontSize: 18,
                  color: _wakeWordDetected ? Colors.green.shade700 : Colors.grey,
                ),
              ),
              const SizedBox(height: 40),
              ElevatedButton(
                onPressed: _isListening ? _stopWakeWordDetection : _startWakeWordDetection,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isListening ? Colors.redAccent : Colors.green,
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  textStyle: const TextStyle(fontSize: 18),
                ),
                child: Text(_isListening ? 'Stop Listening' : 'Start Listening'),
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
    );
  }
}