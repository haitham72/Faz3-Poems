# Installation Guide

## Prerequisites

### 1. Install FFmpeg

FFmpeg is required for audio/video processing.

**Windows (Recommended - Using Chocolatey):**

```bash
choco install ffmpeg
```

**Windows (Manual):**

1. Download from: https://ffmpeg.org/download.html
2. Extract to `C:\ffmpeg`
3. Add `C:\ffmpeg\bin` to your PATH environment variable
4. Restart your terminal

**Verify Installation:**

```bash
ffmpeg -version
```

### 2. Install Python Packages

```bash
cd "Audio Recognition"
pip install -r requirements.txt
```

**If you encounter errors:**

Try installing packages individually:

```bash
pip install resemblyzer torch torchaudio
pip install pydub ffmpeg-python librosa soundfile
pip install noisereduce pandas scikit-learn tqdm python-dotenv
```

### 3. Verify GPU Support (Optional)

```bash
python -c "import torch; print(f'CUDA Available: {torch.cuda.is_available()}')"
```

If CUDA is not available:

- The system will automatically use CPU (slower but functional)
- Or set `USE_GPU = False` in `config.py`

## Common Installation Issues

### Issue: FFmpeg not found

**Solution:**

- Ensure FFmpeg is installed and in PATH
- Restart terminal after installation
- Test with: `ffmpeg -version`

### Issue: torch/CUDA errors

**Solution:**

- Install PyTorch with CUDA support:
  ```bash
  pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
  ```

### Issue: webrtcvad build errors (Windows)

**Solution:**

- This is expected on Windows
- The system automatically uses energy-based silence detection as fallback
- No action needed

### Issue: numpy version conflicts

**Solution:**

```bash
pip install "numpy>=1.24.0,<2.0.0"
```

## Verify Installation

Test that everything works:

```bash
python -c "import resemblyzer, torch, librosa, pydub; print('All core packages installed successfully!')"
```

## Next Steps

Once installed, see [README.md](README.md) for usage instructions.
