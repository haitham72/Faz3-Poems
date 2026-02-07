"""
Batch Processing Module
Handles batch processing of audio files with dynamic monitoring
"""

import logging
from pathlib import Path
from typing import List, Dict, Optional
from datetime import datetime
import time
from tqdm import tqdm

import config
from utils import (
    logger, find_audio_files, get_file_metadata, generate_uuid,
    load_processing_state, save_processing_state, is_file_processed, mark_file_processed,
    save_results_to_csv, save_summary_json
)
from audio_processor import AudioProcessor
from speaker_recognition import SpeakerRecognition


class BatchProcessor:
    """Handles batch processing of audio files"""
    
    def __init__(self):
        self.audio_processor = AudioProcessor()
        self.speaker_recognition = SpeakerRecognition()
        self.processing_state = load_processing_state()
        
    def process_single_file(self, file_path: Path) -> Dict:
        """
        Process a single audio file
        
        Args:
            file_path: Path to audio file
            
        Returns:
            Dictionary with processing results
        """
        try:
            # Get file metadata
            metadata = get_file_metadata(file_path)
            
            # Process audio
            audio, sample_rate, original_duration = self.audio_processor.process_audio_file(file_path)
            
            # Extract speaker embedding
            embedding = self.speaker_recognition.extract_embedding(audio, sample_rate)
            
            # Identify speaker
            speaker_name, confidence = self.speaker_recognition.auto_assign_speaker(embedding)
            
            # Calculate active speech duration
            active_duration = len(audio) / sample_rate
            
            # Create result dictionary
            result = {
                'uuid': generate_uuid(),
                'name': speaker_name,
                'path': metadata['path'],
                'duration': round(original_duration, 2),
                'active_speech_duration': round(active_duration, 2),
                'extension': metadata['extension'],
                'confidence_score': round(confidence, 3),
                'created_at': metadata['created_at'],
                'updated_at': metadata['updated_at'],
                'processed_at': datetime.now().isoformat(),
                'file_size_mb': metadata['file_size_mb'],
                'sample_rate': sample_rate,
                'is_video_source': metadata['is_video_source']
            }
            
            logger.info(f"Processed {file_path.name}: {speaker_name} (confidence: {confidence:.3f})")
            return result
            
        except Exception as e:
            logger.error(f"Error processing {file_path}: {e}")
            
            # Return error result
            metadata = get_file_metadata(file_path)
            return {
                'uuid': generate_uuid(),
                'name': 'ERROR',
                'path': metadata['path'],
                'duration': 0,
                'active_speech_duration': 0,
                'extension': metadata['extension'],
                'confidence_score': 0,
                'created_at': metadata['created_at'],
                'updated_at': metadata['updated_at'],
                'processed_at': datetime.now().isoformat(),
                'file_size_mb': metadata['file_size_mb'],
                'sample_rate': 0,
                'is_video_source': metadata['is_video_source'],
                'error': str(e)
            }
    
    def process_batch(self, input_folder: str, output_folder: Optional[str] = None,
                     skip_processed: bool = True) -> List[Dict]:
        """
        Process all audio files in a folder
        
        Args:
            input_folder: Path to input folder
            output_folder: Optional output folder for reports
            skip_processed: Whether to skip already-processed files
            
        Returns:
            List of processing results
        """
        logger.info(f"Starting batch processing: {input_folder}")
        
        # Find all audio files
        audio_files = find_audio_files(input_folder, recursive=config.RECURSIVE_SCAN)
        
        if not audio_files:
            logger.warning(f"No audio files found in {input_folder}")
            return []
        
        logger.info(f"Found {len(audio_files)} audio files")
        
        # Filter out already-processed files if requested
        if skip_processed and config.SKIP_PROCESSED:
            files_to_process = [
                f for f in audio_files
                if not is_file_processed(f, self.processing_state)
            ]
            skipped = len(audio_files) - len(files_to_process)
            if skipped > 0:
                logger.info(f"Skipping {skipped} already-processed files")
        else:
            files_to_process = audio_files
        
        if not files_to_process:
            logger.info("All files already processed")
            return []
        
        logger.info(f"Processing {len(files_to_process)} files")
        
        # Process files
        results = []
        
        for file_path in tqdm(files_to_process, desc="Processing audio files"):
            result = self.process_single_file(file_path)
            results.append(result)
            
            # Mark as processed
            mark_file_processed(file_path, self.processing_state, result)
            
            # Save state periodically
            if len(results) % 10 == 0:
                save_processing_state(self.processing_state)
        
        # Save final state
        save_processing_state(self.processing_state)
        
        # Save results
        if output_folder:
            output_path = Path(output_folder)
        else:
            output_path = config.REPORTS_DIR
        
        output_path.mkdir(parents=True, exist_ok=True)
        
        csv_path = save_results_to_csv(results, output_path / "classification_results.csv")
        json_path = save_summary_json(results, output_path / "summary.json")
        
        logger.info(f"Batch processing complete: {len(results)} files processed")
        logger.info(f"Results saved to: {csv_path}")
        logger.info(f"Summary saved to: {json_path}")
        
        # Print summary
        self._print_summary(results)
        
        return results
    
    def watch_folder(self, input_folder: str, output_folder: Optional[str] = None):
        """
        Continuously monitor folder for new files and process them
        
        Args:
            input_folder: Path to input folder
            output_folder: Optional output folder for reports
        """
        logger.info(f"Starting watch mode on: {input_folder}")
        logger.info(f"Checking for new files every {config.WATCH_MODE_INTERVAL} seconds")
        logger.info("Press Ctrl+C to stop")
        
        try:
            while True:
                # Find new files
                audio_files = find_audio_files(input_folder, recursive=config.RECURSIVE_SCAN)
                new_files = [
                    f for f in audio_files
                    if not is_file_processed(f, self.processing_state)
                ]
                
                if new_files:
                    logger.info(f"Found {len(new_files)} new files")
                    
                    # Process new files
                    results = []
                    for file_path in new_files:
                        result = self.process_single_file(file_path)
                        results.append(result)
                        mark_file_processed(file_path, self.processing_state, result)
                    
                    # Save state
                    save_processing_state(self.processing_state)
                    
                    # Append to CSV
                    if output_folder:
                        output_path = Path(output_folder)
                    else:
                        output_path = config.REPORTS_DIR
                    
                    csv_path = output_path / "classification_results.csv"
                    save_results_to_csv(results, csv_path)
                    
                    logger.info(f"Processed {len(results)} new files")
                
                # Wait before next check
                time.sleep(config.WATCH_MODE_INTERVAL)
                
        except KeyboardInterrupt:
            logger.info("Watch mode stopped by user")
    
    def _print_summary(self, results: List[Dict]):
        """
        Print processing summary
        
        Args:
            results: List of processing results
        """
        print("\n" + "="*60)
        print("PROCESSING SUMMARY")
        print("="*60)
        
        # Count speakers
        speaker_counts = {}
        total_duration = 0
        errors = 0
        
        for result in results:
            speaker_name = result.get('name', 'unknown')
            speaker_counts[speaker_name] = speaker_counts.get(speaker_name, 0) + 1
            total_duration += result.get('duration', 0)
            
            if speaker_name == 'ERROR':
                errors += 1
        
        print(f"Total files processed: {len(results)}")
        print(f"Total duration: {total_duration/3600:.2f} hours")
        print(f"Errors: {errors}")
        print(f"\nSpeaker distribution:")
        
        for speaker, count in sorted(speaker_counts.items(), key=lambda x: x[1], reverse=True):
            percentage = (count / len(results)) * 100
            print(f"  {speaker}: {count} files ({percentage:.1f}%)")
        
        print("="*60 + "\n")
    
    def organize_by_speaker(self, results: List[Dict], output_folder: str):
        """
        Organize audio files into folders by speaker
        
        Args:
            results: List of processing results
            output_folder: Output folder for organized files
        """
        import shutil
        
        output_path = Path(output_folder)
        output_path.mkdir(parents=True, exist_ok=True)
        
        logger.info(f"Organizing files by speaker in: {output_folder}")
        
        for result in results:
            speaker_name = result.get('name', 'unknown')
            source_path = Path(result['path'])
            
            # Create speaker folder
            speaker_folder = output_path / speaker_name
            speaker_folder.mkdir(exist_ok=True)
            
            # Copy file
            dest_path = speaker_folder / source_path.name
            
            try:
                shutil.copy2(source_path, dest_path)
                logger.debug(f"Copied {source_path.name} to {speaker_name}/")
            except Exception as e:
                logger.error(f"Error copying {source_path.name}: {e}")
        
        logger.info("File organization complete")


# ============================================================================
# CONVENIENCE FUNCTIONS
# ============================================================================

def process_folder(input_folder: str, output_folder: Optional[str] = None) -> List[Dict]:
    """
    Convenience function to process a folder
    
    Args:
        input_folder: Path to input folder
        output_folder: Optional output folder for reports
        
    Returns:
        List of processing results
    """
    processor = BatchProcessor()
    return processor.process_batch(input_folder, output_folder)
