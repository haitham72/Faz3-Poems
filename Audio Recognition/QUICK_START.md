# Quick Reference - Audio Speaker Recognition System

## 📁 Location

```
d:\Jobs\HH\Poem\POETRY-rag\poetry-dashboard\Audio Recognition\
```

## 🚀 Quick Commands

### Install Dependencies

```bash
cd "d:\Jobs\HH\Poem\POETRY-rag\poetry-dashboard\Audio Recognition"
pip install resemblyzer torch torchaudio pydub ffmpeg-python librosa soundfile noisereduce pandas scikit-learn tqdm python-dotenv
```

### Enroll Narrator

```bash
python main.py --mode enroll
```

### Process Files

```bash
python main.py --mode classify --input "path/to/audio/folder"
```

### Watch Folder

```bash
python main.py --mode watch --input "path/to/audio/folder"
```

## 📊 Output Location

```
d:\Jobs\HH\Poem\POETRY-rag\poetry-dashboard\Audio Recognition\output\reports\
```

## 📚 Documentation Files

- `README.md` - Quick start
- `INSTALL.md` - Installation guide
- `README_speaker_recognition.md` - Full documentation

## ⚙️ Configuration

Edit `config.py` to adjust:

- Similarity thresholds
- GPU settings
- Audio processing parameters
- CSV output columns
