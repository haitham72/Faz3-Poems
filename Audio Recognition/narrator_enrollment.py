"""
Narrator Enrollment Module
Interactive system to create narrator voice profiles
"""

import logging
from pathlib import Path
from typing import List, Optional
import numpy as np

import config
from utils import logger, find_audio_files
from audio_processor import AudioProcessor
from speaker_recognition import SpeakerRecognition


class NarratorEnrollment:
    """Handles narrator enrollment and profile creation"""
    
    def __init__(self):
        self.audio_processor = AudioProcessor()
        self.speaker_recognition = SpeakerRecognition()
        
    def enroll_from_folder(self, folder_path: str, narrator_name: Optional[str] = None) -> dict:
        """
        Enroll narrator from audio samples in a folder
        
        Args:
            folder_path: Path to folder containing narrator samples
            narrator_name: Optional custom name for narrator
            
        Returns:
            Dictionary with enrollment results
        """
        logger.info(f"Starting narrator enrollment from: {folder_path}")
        
        # Find audio files
        audio_files = find_audio_files(folder_path, recursive=False)
        
        if not audio_files:
            raise ValueError(f"No audio files found in {folder_path}")
        
        logger.info(f"Found {len(audio_files)} audio files")
        
        # Limit number of samples
        if len(audio_files) > config.MAX_NARRATOR_SAMPLES:
            logger.warning(f"Too many files ({len(audio_files)}), using first {config.MAX_NARRATOR_SAMPLES}")
            audio_files = audio_files[:config.MAX_NARRATOR_SAMPLES]
        
        # Process each file and extract embeddings
        embeddings = []
        processed_files = []
        
        for i, audio_file in enumerate(audio_files, 1):
            try:
                logger.info(f"Processing sample {i}/{len(audio_files)}: {audio_file.name}")
                
                # Process audio
                audio, sample_rate, original_duration = self.audio_processor.process_audio_file(audio_file)
                
                # Check if we have enough audio
                active_duration = len(audio) / sample_rate
                if active_duration < config.MIN_DURATION:
                    logger.warning(f"Skipping {audio_file.name}: insufficient audio ({active_duration:.1f}s)")
                    continue
                
                # Extract embedding
                embedding = self.speaker_recognition.extract_embedding(audio, sample_rate)
                
                embeddings.append(embedding)
                processed_files.append(audio_file.name)
                
            except Exception as e:
                logger.error(f"Error processing {audio_file.name}: {e}")
                continue
        
        if not embeddings:
            raise ValueError("No valid audio samples could be processed")
        
        logger.info(f"Successfully processed {len(embeddings)} samples")
        
        # Check minimum requirements
        if len(embeddings) < config.MIN_NARRATOR_SAMPLES:
            logger.warning(f"Only {len(embeddings)} samples (minimum: {config.MIN_NARRATOR_SAMPLES})")
        
        # Create narrator profile
        consistency = self.speaker_recognition.update_narrator_profile(
            embeddings,
            name=narrator_name
        )
        
        # Evaluate quality
        quality_assessment = self._assess_quality(consistency, len(embeddings))
        
        result = {
            'success': True,
            'narrator_name': narrator_name or config.NARRATOR_DEFAULT_NAME,
            'num_samples': len(embeddings),
            'processed_files': processed_files,
            'consistency_score': consistency,
            'quality_assessment': quality_assessment
        }
        
        logger.info(f"Narrator enrollment complete: {result}")
        return result
    
    def enroll_from_single_file(self, file_path: str, narrator_name: Optional[str] = None) -> dict:
        """
        Enroll narrator from a single audio file
        
        Args:
            file_path: Path to audio file
            narrator_name: Optional custom name for narrator
            
        Returns:
            Dictionary with enrollment results
        """
        logger.info(f"Enrolling narrator from single file: {file_path}")
        
        file_path = Path(file_path)
        
        if not file_path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")
        
        # Process audio
        audio, sample_rate, original_duration = self.audio_processor.process_audio_file(file_path)
        
        # Check duration
        active_duration = len(audio) / sample_rate
        if active_duration < config.MIN_DURATION:
            raise ValueError(f"Insufficient audio: {active_duration:.1f}s (minimum: {config.MIN_DURATION}s)")
        
        # Extract embedding
        embedding = self.speaker_recognition.extract_embedding(audio, sample_rate)
        
        # Create profile with single sample
        self.speaker_recognition.update_narrator_profile(
            [embedding],
            name=narrator_name
        )
        
        result = {
            'success': True,
            'narrator_name': narrator_name or config.NARRATOR_DEFAULT_NAME,
            'num_samples': 1,
            'processed_files': [file_path.name],
            'consistency_score': 1.0,  # Single sample = perfect consistency
            'quality_assessment': 'Single sample - recommend adding more for better accuracy'
        }
        
        logger.info(f"Narrator enrollment complete: {result}")
        return result
    
    def _assess_quality(self, consistency: float, num_samples: int) -> str:
        """
        Assess the quality of narrator enrollment
        
        Args:
            consistency: Consistency score
            num_samples: Number of samples
            
        Returns:
            Quality assessment string
        """
        if consistency < config.MIN_CONSISTENCY_SCORE:
            return f"⚠️ Low consistency ({consistency:.2f}). Samples may be from different speakers or poor quality."
        
        if num_samples < config.RECOMMENDED_NARRATOR_SAMPLES:
            return f"✓ Good quality, but recommend {config.RECOMMENDED_NARRATOR_SAMPLES}+ samples for best accuracy"
        
        if consistency >= 0.8:
            return f"✓ Excellent quality! High consistency ({consistency:.2f}) with {num_samples} samples"
        
        return f"✓ Good quality. Consistency: {consistency:.2f}, Samples: {num_samples}"
    
    def interactive_enrollment(self) -> dict:
        """
        Interactive enrollment process with user prompts
        
        Returns:
            Dictionary with enrollment results
        """
        print("\n" + "="*60)
        print("NARRATOR ENROLLMENT")
        print("="*60)
        
        # Ask for input method
        print("\nHow would you like to provide narrator samples?")
        print("1. Folder containing multiple samples (recommended)")
        print("2. Single audio file")
        
        choice = input("\nEnter choice (1 or 2): ").strip()
        
        if choice == "1":
            folder_path = input("\nEnter folder path containing narrator samples: ").strip()
            folder_path = folder_path.strip('"\'')  # Remove quotes if present
            
            narrator_name = input(f"\nEnter narrator name (press Enter for '{config.NARRATOR_DEFAULT_NAME}'): ").strip()
            narrator_name = narrator_name if narrator_name else None
            
            result = self.enroll_from_folder(folder_path, narrator_name)
            
        elif choice == "2":
            file_path = input("\nEnter audio file path: ").strip()
            file_path = file_path.strip('"\'')  # Remove quotes if present
            
            narrator_name = input(f"\nEnter narrator name (press Enter for '{config.NARRATOR_DEFAULT_NAME}'): ").strip()
            narrator_name = narrator_name if narrator_name else None
            
            result = self.enroll_from_single_file(file_path, narrator_name)
            
        else:
            raise ValueError("Invalid choice. Please enter 1 or 2.")
        
        # Display results
        print("\n" + "="*60)
        print("ENROLLMENT RESULTS")
        print("="*60)
        print(f"Narrator Name: {result['narrator_name']}")
        print(f"Samples Processed: {result['num_samples']}")
        print(f"Consistency Score: {result['consistency_score']:.3f}")
        print(f"Quality: {result['quality_assessment']}")
        print("\nProcessed files:")
        for filename in result['processed_files']:
            print(f"  - {filename}")
        print("="*60)
        
        return result


# ============================================================================
# CONVENIENCE FUNCTIONS
# ============================================================================

def enroll_narrator_interactive() -> dict:
    """
    Convenience function for interactive narrator enrollment
    
    Returns:
        Dictionary with enrollment results
    """
    enrollment = NarratorEnrollment()
    return enrollment.interactive_enrollment()


def enroll_narrator_from_folder(folder_path: str, narrator_name: Optional[str] = None) -> dict:
    """
    Convenience function to enroll narrator from folder
    
    Args:
        folder_path: Path to folder containing narrator samples
        narrator_name: Optional custom name for narrator
        
    Returns:
        Dictionary with enrollment results
    """
    enrollment = NarratorEnrollment()
    return enrollment.enroll_from_folder(folder_path, narrator_name)
