"""
Utility functions for the Audio Speaker Recognition System
"""

import os
import json
import uuid
import logging
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Any, Optional, Tuple
import pandas as pd

import config


# ============================================================================
# LOGGING SETUP
# ============================================================================

def setup_logging():
    """Configure logging for the application"""
    logging.basicConfig(
        level=getattr(logging, config.LOG_LEVEL),
        format=config.LOG_FORMAT,
        handlers=[
            logging.FileHandler(config.LOG_FILE),
            logging.StreamHandler()
        ]
    )
    return logging.getLogger(__name__)


logger = setup_logging()


# ============================================================================
# FILE OPERATIONS
# ============================================================================

def find_audio_files(root_dir: str, recursive: bool = True) -> List[Path]:
    """
    Find all supported audio/video files in a directory
    
    Args:
        root_dir: Root directory to search
        recursive: Whether to search subdirectories
        
    Returns:
        List of Path objects for found files
    """
    root_path = Path(root_dir)
    files = []
    
    if not root_path.exists():
        logger.error(f"Directory does not exist: {root_dir}")
        return files
    
    if recursive:
        for ext in config.SUPPORTED_EXTENSIONS:
            files.extend(root_path.rglob(f"*{ext}"))
    else:
        for ext in config.SUPPORTED_EXTENSIONS:
            files.extend(root_path.glob(f"*{ext}"))
    
    logger.info(f"Found {len(files)} audio/video files in {root_dir}")
    return sorted(files)


def get_file_metadata(file_path: Path) -> Dict[str, Any]:
    """
    Extract metadata from a file
    
    Args:
        file_path: Path to the file
        
    Returns:
        Dictionary with file metadata
    """
    stat = file_path.stat()
    
    return {
        'path': str(file_path.absolute()),
        'extension': file_path.suffix.lower(),
        'file_size_mb': round(stat.st_size / (1024 * 1024), 2),
        'created_at': datetime.fromtimestamp(stat.st_ctime).isoformat(),
        'updated_at': datetime.fromtimestamp(stat.st_mtime).isoformat(),
        'is_video_source': file_path.suffix.lower() in config.VIDEO_EXTENSIONS
    }


def generate_uuid() -> str:
    """Generate a unique UUID for a file"""
    return str(uuid.uuid4())


# ============================================================================
# STATE MANAGEMENT
# ============================================================================

def load_processing_state() -> Dict[str, Any]:
    """
    Load the processing state from disk
    
    Returns:
        Dictionary with processing state
    """
    if config.STATE_FILE.exists():
        try:
            with open(config.STATE_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Error loading state file: {e}")
            return {'processed_files': {}, 'last_updated': None}
    return {'processed_files': {}, 'last_updated': None}


def save_processing_state(state: Dict[str, Any]):
    """
    Save the processing state to disk
    
    Args:
        state: Dictionary with processing state
    """
    state['last_updated'] = datetime.now().isoformat()
    try:
        with open(config.STATE_FILE, 'w', encoding='utf-8') as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
        logger.debug("Processing state saved")
    except Exception as e:
        logger.error(f"Error saving state file: {e}")


def is_file_processed(file_path: Path, state: Dict[str, Any]) -> bool:
    """
    Check if a file has already been processed
    
    Args:
        file_path: Path to the file
        state: Processing state dictionary
        
    Returns:
        True if file has been processed
    """
    file_key = str(file_path.absolute())
    return file_key in state.get('processed_files', {})


def mark_file_processed(file_path: Path, state: Dict[str, Any], result: Dict[str, Any]):
    """
    Mark a file as processed
    
    Args:
        file_path: Path to the file
        state: Processing state dictionary
        result: Processing result dictionary
    """
    file_key = str(file_path.absolute())
    state.setdefault('processed_files', {})[file_key] = {
        'processed_at': datetime.now().isoformat(),
        'uuid': result.get('uuid'),
        'speaker_name': result.get('name')
    }


# ============================================================================
# SPEAKER PROFILE MANAGEMENT
# ============================================================================

def load_profile_registry() -> Dict[str, Any]:
    """
    Load the speaker profile registry
    
    Returns:
        Dictionary with speaker profiles
    """
    if config.PROFILE_REGISTRY.exists():
        try:
            with open(config.PROFILE_REGISTRY, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Error loading profile registry: {e}")
            return {'profiles': {}, 'next_voice_id': 1}
    return {'profiles': {}, 'next_voice_id': 1}


def save_profile_registry(registry: Dict[str, Any]):
    """
    Save the speaker profile registry
    
    Args:
        registry: Dictionary with speaker profiles
    """
    try:
        with open(config.PROFILE_REGISTRY, 'w', encoding='utf-8') as f:
            json.dump(registry, f, indent=2, ensure_ascii=False)
        logger.debug("Profile registry saved")
    except Exception as e:
        logger.error(f"Error saving profile registry: {e}")


def get_next_voice_name(registry: Dict[str, Any]) -> str:
    """
    Generate the next voice name (e.g., voice_01, voice_02)
    
    Args:
        registry: Profile registry dictionary
        
    Returns:
        Next voice name
    """
    voice_id = registry.get('next_voice_id', 1)
    voice_name = f"{config.VOICE_NAME_PREFIX}{voice_id:0{config.VOICE_NAME_DIGITS}d}"
    registry['next_voice_id'] = voice_id + 1
    return voice_name


# ============================================================================
# CSV REPORT GENERATION
# ============================================================================

def save_results_to_csv(results: List[Dict[str, Any]], output_path: Optional[Path] = None):
    """
    Save processing results to CSV
    
    Args:
        results: List of result dictionaries
        output_path: Optional custom output path
    """
    if not results:
        logger.warning("No results to save")
        return
    
    if output_path is None:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = config.REPORTS_DIR / f"speaker_recognition_{timestamp}.csv"
    
    # Create DataFrame with specified column order
    df = pd.DataFrame(results)
    
    # Ensure all required columns exist
    for col in config.CSV_COLUMNS:
        if col not in df.columns:
            df[col] = None
    
    # Reorder columns
    df = df[config.CSV_COLUMNS]
    
    # Save to CSV
    df.to_csv(output_path, index=False, encoding='utf-8')
    logger.info(f"Results saved to: {output_path}")
    
    return output_path


def save_summary_json(results: List[Dict[str, Any]], output_path: Optional[Path] = None):
    """
    Save processing summary as JSON
    
    Args:
        results: List of result dictionaries
        output_path: Optional custom output path
    """
    if output_path is None:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = config.REPORTS_DIR / f"summary_{timestamp}.json"
    
    # Calculate statistics
    total_files = len(results)
    speaker_counts = {}
    total_duration = 0
    
    for result in results:
        speaker_name = result.get('name', 'unknown')
        speaker_counts[speaker_name] = speaker_counts.get(speaker_name, 0) + 1
        total_duration += result.get('duration', 0)
    
    summary = {
        'total_files_processed': total_files,
        'total_duration_hours': round(total_duration / 3600, 2),
        'speaker_distribution': speaker_counts,
        'processing_timestamp': datetime.now().isoformat(),
        'unique_speakers': len(speaker_counts)
    }
    
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    
    logger.info(f"Summary saved to: {output_path}")
    return output_path


# ============================================================================
# PROGRESS TRACKING
# ============================================================================

def print_progress_bar(iteration: int, total: int, prefix: str = '', suffix: str = '', length: int = 50):
    """
    Print a progress bar to console
    
    Args:
        iteration: Current iteration
        total: Total iterations
        prefix: Prefix string
        suffix: Suffix string
        length: Bar length
    """
    percent = f"{100 * (iteration / float(total)):.1f}"
    filled_length = int(length * iteration // total)
    bar = '█' * filled_length + '-' * (length - filled_length)
    print(f'\r{prefix} |{bar}| {percent}% {suffix}', end='\r')
    if iteration == total:
        print()


# ============================================================================
# VALIDATION
# ============================================================================

def validate_audio_duration(duration: float) -> bool:
    """
    Check if audio duration meets minimum requirements
    
    Args:
        duration: Audio duration in seconds
        
    Returns:
        True if duration is sufficient
    """
    return duration >= config.MIN_DURATION


def validate_confidence_score(score: float) -> bool:
    """
    Check if confidence score is valid
    
    Args:
        score: Confidence score (0-1)
        
    Returns:
        True if score is valid
    """
    return 0 <= score <= 1
