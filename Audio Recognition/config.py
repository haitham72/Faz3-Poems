"""
Configuration settings for the Audio Speaker Recognition System
"""

import os
from pathlib import Path

# ============================================================================
# PATHS
# ============================================================================

# Base directory for the project
BASE_DIR = Path(__file__).parent

# Output directories
OUTPUT_DIR = BASE_DIR / "output"
PROFILES_DIR = OUTPUT_DIR / "speaker_profiles"
REPORTS_DIR = OUTPUT_DIR / "reports"
TEMP_DIR = OUTPUT_DIR / "temp"
CLASSIFIED_DIR = OUTPUT_DIR / "classified_audio"

# Create directories if they don't exist
for directory in [OUTPUT_DIR, PROFILES_DIR, REPORTS_DIR, TEMP_DIR, CLASSIFIED_DIR]:
    directory.mkdir(parents=True, exist_ok=True)

# ============================================================================
# AUDIO PROCESSING SETTINGS
# ============================================================================

# Supported audio formats
AUDIO_EXTENSIONS = ['.mp3', '.wav', '.m4a', '.flac', '.ogg', '.aac', '.wma']

# Supported video formats (audio will be extracted)
VIDEO_EXTENSIONS = ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm']

# All supported formats
SUPPORTED_EXTENSIONS = AUDIO_EXTENSIONS + VIDEO_EXTENSIONS

# Audio processing parameters
SAMPLE_RATE = 16000  # Hz - Standard for speech recognition
TARGET_DURATION = 10  # seconds - Extract first 10 seconds of active speech
MIN_DURATION = 5  # seconds - Minimum duration for processing

# Voice Activity Detection (VAD) settings
VAD_AGGRESSIVENESS = 3  # 0-3, higher = more aggressive silence removal
VAD_FRAME_DURATION = 30  # ms - Frame duration for VAD (10, 20, or 30)
SILENCE_THRESHOLD_DB = -40  # dB - Threshold for silence detection

# Audio cleaning
NOISE_REDUCTION_ENABLED = True
NOISE_REDUCTION_STRENGTH = 0.5  # 0-1, higher = more aggressive

# ============================================================================
# SPEAKER RECOGNITION SETTINGS
# ============================================================================

# Similarity thresholds
NARRATOR_SIMILARITY_THRESHOLD = 0.75  # Minimum similarity to identify as narrator
NEW_SPEAKER_THRESHOLD = 0.70  # Minimum similarity to group as same speaker
CLUSTERING_THRESHOLD = 0.65  # Threshold for automatic speaker clustering

# Embedding settings
EMBEDDING_DIM = 256  # Resemblyzer embedding dimension

# GPU settings
USE_GPU = True  # Set to False to use CPU only
GPU_DEVICE = 0  # GPU device ID (0 for first GPU)

# ============================================================================
# BATCH PROCESSING SETTINGS
# ============================================================================

# Processing parameters
BATCH_SIZE = 10  # Number of files to process in parallel
RECURSIVE_SCAN = True  # Scan subfolders recursively
SKIP_PROCESSED = True  # Skip files that have already been processed

# Watch mode settings
WATCH_MODE_INTERVAL = 5  # seconds - How often to check for new files
WATCH_MODE_ENABLED = False  # Enable continuous monitoring

# ============================================================================
# CSV OUTPUT SCHEMA
# ============================================================================

CSV_COLUMNS = [
    'uuid',
    'name',
    'path',
    'duration',
    'active_speech_duration',
    'extension',
    'confidence_score',
    'created_at',
    'updated_at',
    'processed_at',
    'file_size_mb',
    'sample_rate',
    'is_video_source'
]

# ============================================================================
# LOGGING SETTINGS
# ============================================================================

LOG_LEVEL = "INFO"  # DEBUG, INFO, WARNING, ERROR, CRITICAL
LOG_FILE = OUTPUT_DIR / "speaker_recognition.log"
LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"

# ============================================================================
# NARRATOR ENROLLMENT SETTINGS
# ============================================================================

MIN_NARRATOR_SAMPLES = 1  # Minimum number of samples required
RECOMMENDED_NARRATOR_SAMPLES = 3  # Recommended number for best accuracy
MAX_NARRATOR_SAMPLES = 10  # Maximum number to process

# Quality thresholds
MIN_SAMPLE_QUALITY = 0.5  # Minimum quality score for a sample
MIN_CONSISTENCY_SCORE = 0.6  # Minimum consistency across samples

# ============================================================================
# FILE NAMING
# ============================================================================

# Voice naming pattern
VOICE_NAME_PREFIX = "voice_"
VOICE_NAME_DIGITS = 2  # Number of digits (e.g., voice_01, voice_02)

# Narrator default name
NARRATOR_DEFAULT_NAME = "narrator"

# ============================================================================
# PROCESSING STATE
# ============================================================================

STATE_FILE = OUTPUT_DIR / "processing_state.json"
PROFILE_REGISTRY = PROFILES_DIR / "profile_registry.json"
