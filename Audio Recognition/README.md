# Audio Speaker Recognition System

A GPU-accelerated system for identifying and classifying speakers in audio files.

## Quick Installation

```bash
cd "Audio Recognition"
pip install -r requirements.txt
```

## Quick Start

1. **Enroll Narrator:**

   ```bash
   python main.py --mode enroll
   ```

2. **Process Audio Files:**

   ```bash
   python main.py --mode classify --input "path/to/audio/folder"
   ```

3. **View Results:**
   - Check `output/reports/classification_results.csv`

## Full Documentation

See [README_speaker_recognition.md](README_speaker_recognition.md) for complete documentation.

## System Requirements

- Python 3.8+
- FFmpeg (for audio/video processing)
- NVIDIA GPU with CUDA (optional, for acceleration)

## Files

- `main.py` - Main CLI application
- `config.py` - Configuration settings
- `audio_processor.py` - Audio processing
- `speaker_recognition.py` - Speaker identification
- `narrator_enrollment.py` - Enrollment system
- `batch_processor.py` - Batch processing
- `utils.py` - Utility functions
- `requirements.txt` - Python dependencies
- `README_speaker_recognition.md` - Full documentation
