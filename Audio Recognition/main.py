"""
Main Application - Audio Speaker Recognition System
Command-line interface for speaker recognition and classification
"""

import argparse
import sys
from pathlib import Path

from utils import logger
from narrator_enrollment import NarratorEnrollment, enroll_narrator_interactive
from batch_processor import BatchProcessor
from speaker_recognition import SpeakerRecognition
import config


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="Audio Speaker Recognition System - Identify and classify speakers in audio files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Interactive narrator enrollment
  python main.py --mode enroll
  
  # Enroll narrator from folder
  python main.py --mode enroll --input ./narrator_samples --name "John Doe"
  
  # Process all files in folder
  python main.py --mode classify --input ./audio_files
  
  # Watch folder for new files
  python main.py --mode watch --input ./audio_files
  
  # Test single file
  python main.py --mode test --input ./test_audio.mp3
  
  # Manage speakers
  python main.py --mode manage
        """
    )
    
    parser.add_argument(
        '--mode',
        choices=['enroll', 'classify', 'watch', 'test', 'manage', 'export'],
        required=True,
        help='Operation mode'
    )
    
    parser.add_argument(
        '--input',
        type=str,
        help='Input folder or file path'
    )
    
    parser.add_argument(
        '--output',
        type=str,
        help='Output folder for reports (default: ./output/reports)'
    )
    
    parser.add_argument(
        '--name',
        type=str,
        help='Speaker name (for enrollment mode)'
    )
    
    parser.add_argument(
        '--organize',
        action='store_true',
        help='Organize files by speaker after classification'
    )
    
    parser.add_argument(
        '--no-skip',
        action='store_true',
        help='Process all files, even if already processed'
    )
    
    args = parser.parse_args()
    
    try:
        if args.mode == 'enroll':
            handle_enroll(args)
        elif args.mode == 'classify':
            handle_classify(args)
        elif args.mode == 'watch':
            handle_watch(args)
        elif args.mode == 'test':
            handle_test(args)
        elif args.mode == 'manage':
            handle_manage(args)
        elif args.mode == 'export':
            handle_export(args)
            
    except KeyboardInterrupt:
        logger.info("Operation cancelled by user")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Error: {e}")
        sys.exit(1)


def handle_enroll(args):
    """Handle narrator enrollment"""
    enrollment = NarratorEnrollment()
    
    if args.input:
        # Non-interactive enrollment
        input_path = Path(args.input)
        
        if input_path.is_dir():
            result = enrollment.enroll_from_folder(str(input_path), args.name)
        elif input_path.is_file():
            result = enrollment.enroll_from_single_file(str(input_path), args.name)
        else:
            raise ValueError(f"Invalid input path: {args.input}")
    else:
        # Interactive enrollment
        result = enrollment.interactive_enrollment()
    
    if result['success']:
        logger.info("Narrator enrollment successful!")
    else:
        logger.error("Narrator enrollment failed")


def handle_classify(args):
    """Handle batch classification"""
    if not args.input:
        raise ValueError("--input folder is required for classify mode")
    
    processor = BatchProcessor()
    
    results = processor.process_batch(
        args.input,
        args.output,
        skip_processed=not args.no_skip
    )
    
    # Organize files if requested
    if args.organize and results:
        output_folder = args.output or str(config.CLASSIFIED_DIR)
        processor.organize_by_speaker(results, output_folder)


def handle_watch(args):
    """Handle watch mode"""
    if not args.input:
        raise ValueError("--input folder is required for watch mode")
    
    processor = BatchProcessor()
    processor.watch_folder(args.input, args.output)


def handle_test(args):
    """Handle single file test"""
    if not args.input:
        raise ValueError("--input file is required for test mode")
    
    input_path = Path(args.input)
    
    if not input_path.exists():
        raise FileNotFoundError(f"File not found: {args.input}")
    
    processor = BatchProcessor()
    result = processor.process_single_file(input_path)
    
    # Display results
    print("\n" + "="*60)
    print("TEST RESULTS")
    print("="*60)
    print(f"File: {result['path']}")
    print(f"Speaker: {result['name']}")
    print(f"Confidence: {result['confidence_score']:.3f}")
    print(f"Duration: {result['duration']:.2f}s")
    print(f"Active Speech: {result['active_speech_duration']:.2f}s")
    print(f"Sample Rate: {result['sample_rate']}Hz")
    print(f"Video Source: {result['is_video_source']}")
    print("="*60 + "\n")


def handle_manage(args):
    """Handle speaker management"""
    recognition = SpeakerRecognition()
    
    while True:
        print("\n" + "="*60)
        print("SPEAKER MANAGEMENT")
        print("="*60)
        
        # Get stats
        stats = recognition.get_speaker_stats()
        
        print(f"\nTotal Speakers: {stats['total_speakers']}")
        print(f"Has Narrator: {stats['has_narrator']}")
        
        if stats['speakers']:
            print("\nRegistered Speakers:")
            for i, speaker in enumerate(stats['speakers'], 1):
                print(f"  {i}. {speaker}")
        
        print("\nOptions:")
        print("1. View speaker details")
        print("2. Rename speaker")
        print("3. Delete speaker")
        print("4. Exit")
        
        choice = input("\nEnter choice (1-4): ").strip()
        
        if choice == "1":
            speaker_name = input("Enter speaker name: ").strip()
            view_speaker_details(recognition, speaker_name)
        elif choice == "2":
            old_name = input("Enter current speaker name: ").strip()
            new_name = input("Enter new speaker name: ").strip()
            recognition.rename_speaker(old_name, new_name)
            print(f"Renamed {old_name} to {new_name}")
        elif choice == "3":
            speaker_name = input("Enter speaker name to delete: ").strip()
            confirm = input(f"Are you sure you want to delete '{speaker_name}'? (yes/no): ").strip()
            if confirm.lower() == 'yes':
                recognition.delete_speaker(speaker_name)
                print(f"Deleted {speaker_name}")
        elif choice == "4":
            break
        else:
            print("Invalid choice")


def view_speaker_details(recognition, speaker_name):
    """View details of a speaker"""
    profiles = recognition.profile_registry.get('profiles', {})
    
    if speaker_name not in profiles:
        print(f"Speaker not found: {speaker_name}")
        return
    
    profile = profiles[speaker_name]
    
    print("\n" + "-"*60)
    print(f"Speaker: {speaker_name}")
    print("-"*60)
    print(f"Created: {profile.get('created_at', 'Unknown')}")
    
    metadata = profile.get('metadata', {})
    if metadata:
        print("\nMetadata:")
        for key, value in metadata.items():
            print(f"  {key}: {value}")
    
    print("-"*60)


def handle_export(args):
    """Handle export/report generation"""
    print("\n" + "="*60)
    print("EXPORT & REPORTS")
    print("="*60)
    
    recognition = SpeakerRecognition()
    stats = recognition.get_speaker_stats()
    
    print(f"\nTotal Speakers: {stats['total_speakers']}")
    print(f"Speakers: {', '.join(stats['speakers'])}")
    
    print("\nReports are automatically generated during classification.")
    print(f"Check the reports directory: {config.REPORTS_DIR}")
    print("="*60 + "\n")


if __name__ == "__main__":
    main()
