"""
Audio Processing Module
Handles audio loading, silence removal, format conversion, and preprocessing
"""

import os
import logging
from pathlib import Path
from typing import Tuple, Optional
import numpy as np

try:
    import webrtcvad
    VAD_AVAILABLE = True
except ImportError:
    VAD_AVAILABLE = False
    logging.warning("webrtcvad not available - using energy-based silence detection only")

from pydub import AudioSegment
from pydub.silence import detect_nonsilent
import librosa
import soundfile as sf

try:
    import noisereduce as nr
    NOISE_REDUCE_AVAILABLE = True
except ImportError:
    NOISE_REDUCE_AVAILABLE = False
    logging.warning("noisereduce not available - audio cleaning disabled")

import config
from utils import logger


class AudioProcessor:
    """Handles all audio processing operations"""
    
    def __init__(self):
        self.sample_rate = config.SAMPLE_RATE
        self.target_duration = config.TARGET_DURATION
        
        if VAD_AVAILABLE:
            self.vad = webrtcvad.Vad(config.VAD_AGGRESSIVENESS)
        else:
            self.vad = None
            logger.warning("VAD not available, will use energy-based silence detection")
        
    def load_audio(self, file_path: Path) -> Tuple[np.ndarray, int]:
        """
        Load audio from file (supports audio and video files)
        
        Args:
            file_path: Path to audio/video file
            
        Returns:
            Tuple of (audio_data, sample_rate)
        """
        try:
            file_ext = file_path.suffix.lower()
            
            # Check if it's a video file
            if file_ext in config.VIDEO_EXTENSIONS:
                logger.info(f"Extracting audio from video: {file_path.name}")
                audio = AudioSegment.from_file(str(file_path))
            else:
                # Load audio file
                audio = AudioSegment.from_file(str(file_path))
            
            # Convert to mono if stereo
            if audio.channels > 1:
                audio = audio.set_channels(1)
            
            # Resample to target sample rate
            if audio.frame_rate != self.sample_rate:
                audio = audio.set_frame_rate(self.sample_rate)
            
            # Convert to numpy array
            samples = np.array(audio.get_array_of_samples(), dtype=np.float32)
            
            # Normalize to [-1, 1]
            if audio.sample_width == 2:  # 16-bit
                samples = samples / 32768.0
            elif audio.sample_width == 4:  # 32-bit
                samples = samples / 2147483648.0
            
            logger.debug(f"Loaded audio: {len(samples)/self.sample_rate:.2f}s at {self.sample_rate}Hz")
            return samples, self.sample_rate
            
        except Exception as e:
            logger.error(f"Error loading audio from {file_path}: {e}")
            raise
    
    def remove_silence_vad(self, audio: np.ndarray, sample_rate: int) -> np.ndarray:
        """
        Remove silence using Voice Activity Detection
        
        Args:
            audio: Audio data as numpy array
            sample_rate: Sample rate in Hz
            
        Returns:
            Audio with silence removed
        """
        if not VAD_AVAILABLE or self.vad is None:
            logger.debug("VAD not available, using energy-based method")
            return self.remove_silence_energy(audio, sample_rate)
        
        try:
            # Convert to 16-bit PCM for VAD
            audio_int16 = (audio * 32768).astype(np.int16)
            
            # VAD requires specific frame durations (10, 20, or 30 ms)
            frame_duration = config.VAD_FRAME_DURATION  # ms
            frame_size = int(sample_rate * frame_duration / 1000)
            
            # Process audio in frames
            voiced_frames = []
            for i in range(0, len(audio_int16) - frame_size, frame_size):
                frame = audio_int16[i:i + frame_size]
                
                # VAD requires exactly frame_size samples
                if len(frame) == frame_size:
                    # Convert to bytes
                    frame_bytes = frame.tobytes()
                    
                    # Check if frame contains speech
                    try:
                        is_speech = self.vad.is_speech(frame_bytes, sample_rate)
                        if is_speech:
                            voiced_frames.append(frame)
                    except Exception as e:
                        # If VAD fails, keep the frame
                        voiced_frames.append(frame)
            
            if not voiced_frames:
                logger.warning("No speech detected, returning original audio")
                return audio
            
            # Concatenate voiced frames
            voiced_audio = np.concatenate(voiced_frames)
            
            # Convert back to float32
            voiced_audio = voiced_audio.astype(np.float32) / 32768.0
            
            reduction = (1 - len(voiced_audio) / len(audio)) * 100
            logger.debug(f"Removed {reduction:.1f}% silence using VAD")
            
            return voiced_audio
            
        except Exception as e:
            logger.error(f"Error in VAD silence removal: {e}")
            return audio
    
    def remove_silence_energy(self, audio: np.ndarray, sample_rate: int) -> np.ndarray:
        """
        Remove silence using energy-based detection (fallback method)
        
        Args:
            audio: Audio data as numpy array
            sample_rate: Sample rate in Hz
            
        Returns:
            Audio with silence removed
        """
        try:
            # Convert to AudioSegment for pydub processing
            audio_int16 = (audio * 32768).astype(np.int16)
            audio_segment = AudioSegment(
                audio_int16.tobytes(),
                frame_rate=sample_rate,
                sample_width=2,
                channels=1
            )
            
            # Detect non-silent chunks
            nonsilent_ranges = detect_nonsilent(
                audio_segment,
                min_silence_len=300,  # 300ms
                silence_thresh=config.SILENCE_THRESHOLD_DB
            )
            
            if not nonsilent_ranges:
                logger.warning("No non-silent audio detected")
                return audio
            
            # Extract non-silent audio
            nonsilent_audio = AudioSegment.empty()
            for start, end in nonsilent_ranges:
                nonsilent_audio += audio_segment[start:end]
            
            # Convert back to numpy
            samples = np.array(nonsilent_audio.get_array_of_samples(), dtype=np.float32)
            samples = samples / 32768.0
            
            reduction = (1 - len(samples) / len(audio)) * 100
            logger.debug(f"Removed {reduction:.1f}% silence using energy detection")
            
            return samples
            
        except Exception as e:
            logger.error(f"Error in energy-based silence removal: {e}")
            return audio
    
    def clean_audio(self, audio: np.ndarray, sample_rate: int) -> np.ndarray:
        """
        Clean audio by removing noise
        
        Args:
            audio: Audio data as numpy array
            sample_rate: Sample rate in Hz
            
        Returns:
            Cleaned audio
        """
        if not config.NOISE_REDUCTION_ENABLED or not NOISE_REDUCE_AVAILABLE:
            return audio
        
        try:
            # Apply noise reduction
            cleaned = nr.reduce_noise(
                y=audio,
                sr=sample_rate,
                prop_decrease=config.NOISE_REDUCTION_STRENGTH
            )
            logger.debug("Applied noise reduction")
            return cleaned
        except Exception as e:
            logger.error(f"Error in noise reduction: {e}")
            return audio
    
    def normalize_audio(self, audio: np.ndarray) -> np.ndarray:
        """
        Normalize audio to consistent volume level
        
        Args:
            audio: Audio data as numpy array
            
        Returns:
            Normalized audio
        """
        # Normalize to -1 to 1 range
        max_val = np.abs(audio).max()
        if max_val > 0:
            audio = audio / max_val
        
        # Apply gentle compression to bring up quiet parts
        audio = np.tanh(audio * 1.5) / 1.5
        
        return audio
    
    def extract_segment(self, audio: np.ndarray, sample_rate: int, 
                       duration: Optional[float] = None) -> np.ndarray:
        """
        Extract a segment of specified duration from the beginning
        
        Args:
            audio: Audio data as numpy array
            sample_rate: Sample rate in Hz
            duration: Duration in seconds (uses config.TARGET_DURATION if None)
            
        Returns:
            Extracted segment
        """
        if duration is None:
            duration = self.target_duration
        
        target_samples = int(duration * sample_rate)
        
        if len(audio) <= target_samples:
            return audio
        
        return audio[:target_samples]
    
    def process_audio_file(self, file_path: Path) -> Tuple[np.ndarray, int, float]:
        """
        Complete audio processing pipeline
        
        Args:
            file_path: Path to audio/video file
            
        Returns:
            Tuple of (processed_audio, sample_rate, original_duration)
        """
        logger.info(f"Processing: {file_path.name}")
        
        # Load audio
        audio, sample_rate = self.load_audio(file_path)
        original_duration = len(audio) / sample_rate
        
        # Remove silence using VAD
        audio = self.remove_silence_vad(audio, sample_rate)
        
        # If VAD didn't remove much, try energy-based method
        if len(audio) / sample_rate > original_duration * 0.9:
            audio = self.remove_silence_energy(audio, sample_rate)
        
        # Clean audio (noise reduction)
        audio = self.clean_audio(audio, sample_rate)
        
        # Normalize volume
        audio = self.normalize_audio(audio)
        
        # Extract target duration
        audio = self.extract_segment(audio, sample_rate)
        
        active_duration = len(audio) / sample_rate
        logger.info(f"Processed {file_path.name}: {original_duration:.1f}s -> {active_duration:.1f}s active speech")
        
        return audio, sample_rate, original_duration
    
    def save_audio(self, audio: np.ndarray, sample_rate: int, output_path: Path):
        """
        Save audio to file
        
        Args:
            audio: Audio data as numpy array
            sample_rate: Sample rate in Hz
            output_path: Output file path
        """
        try:
            sf.write(str(output_path), audio, sample_rate)
            logger.debug(f"Saved audio to: {output_path}")
        except Exception as e:
            logger.error(f"Error saving audio: {e}")
            raise


# ============================================================================
# CONVENIENCE FUNCTIONS
# ============================================================================

def process_audio(file_path: Path) -> Tuple[np.ndarray, int, float]:
    """
    Convenience function to process an audio file
    
    Args:
        file_path: Path to audio/video file
        
    Returns:
        Tuple of (processed_audio, sample_rate, original_duration)
    """
    processor = AudioProcessor()
    return processor.process_audio_file(file_path)
