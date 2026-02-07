"""
Speaker Recognition Module
Handles speaker embedding extraction, identification, and verification
"""

import logging
from pathlib import Path
from typing import List, Dict, Tuple, Optional
import numpy as np
from resemblyzer import VoiceEncoder, preprocess_wav
from sklearn.cluster import DBSCAN
from scipy.spatial.distance import cosine
import torch

import config
from utils import logger, load_profile_registry, save_profile_registry, get_next_voice_name


class SpeakerRecognition:
    """Handles speaker recognition and identification"""
    
    def __init__(self):
        # Initialize voice encoder
        device = 'cuda' if config.USE_GPU and torch.cuda.is_available() else 'cpu'
        logger.info(f"Initializing speaker recognition on device: {device}")
        
        self.encoder = VoiceEncoder(device=device)
        self.profile_registry = load_profile_registry()
        
    def extract_embedding(self, audio: np.ndarray, sample_rate: int) -> np.ndarray:
        """
        Extract speaker embedding from audio
        
        Args:
            audio: Audio data as numpy array
            sample_rate: Sample rate in Hz
            
        Returns:
            Speaker embedding vector (256-dim)
        """
        try:
            # Preprocess audio for Resemblyzer
            # Resemblyzer expects 16kHz audio
            if sample_rate != 16000:
                logger.warning(f"Audio sample rate is {sample_rate}Hz, Resemblyzer expects 16kHz")
            
            wav = preprocess_wav(audio)
            
            # Extract embedding
            embedding = self.encoder.embed_utterance(wav)
            
            logger.debug(f"Extracted embedding: shape {embedding.shape}")
            return embedding
            
        except Exception as e:
            logger.error(f"Error extracting embedding: {e}")
            raise
    
    def calculate_similarity(self, embedding1: np.ndarray, embedding2: np.ndarray) -> float:
        """
        Calculate similarity between two embeddings
        
        Args:
            embedding1: First embedding
            embedding2: Second embedding
            
        Returns:
            Similarity score (0-1, higher is more similar)
        """
        # Use cosine similarity
        similarity = 1 - cosine(embedding1, embedding2)
        return max(0, min(1, similarity))  # Clamp to [0, 1]
    
    def identify_speaker(self, embedding: np.ndarray) -> Tuple[str, float]:
        """
        Identify speaker from embedding
        
        Args:
            embedding: Speaker embedding
            
        Returns:
            Tuple of (speaker_name, confidence_score)
        """
        profiles = self.profile_registry.get('profiles', {})
        
        if not profiles:
            logger.debug("No speaker profiles available")
            return None, 0.0
        
        best_match = None
        best_score = 0.0
        
        # Compare against all known speakers
        for speaker_name, profile_data in profiles.items():
            profile_embedding = np.array(profile_data['embedding'])
            similarity = self.calculate_similarity(embedding, profile_embedding)
            
            if similarity > best_score:
                best_score = similarity
                best_match = speaker_name
        
        # Check if similarity meets threshold
        if best_match and best_score >= config.NEW_SPEAKER_THRESHOLD:
            logger.debug(f"Identified as {best_match} with confidence {best_score:.3f}")
            return best_match, best_score
        
        logger.debug(f"No match found (best: {best_score:.3f})")
        return None, best_score
    
    def is_narrator(self, embedding: np.ndarray) -> Tuple[bool, float]:
        """
        Check if embedding matches the narrator
        
        Args:
            embedding: Speaker embedding
            
        Returns:
            Tuple of (is_narrator, confidence_score)
        """
        narrator_profile = self.profile_registry.get('profiles', {}).get(config.NARRATOR_DEFAULT_NAME)
        
        if not narrator_profile:
            logger.debug("No narrator profile available")
            return False, 0.0
        
        narrator_embedding = np.array(narrator_profile['embedding'])
        similarity = self.calculate_similarity(embedding, narrator_embedding)
        
        is_narrator = similarity >= config.NARRATOR_SIMILARITY_THRESHOLD
        logger.debug(f"Narrator check: {is_narrator} (similarity: {similarity:.3f})")
        
        return is_narrator, similarity
    
    def register_speaker(self, name: str, embedding: np.ndarray, metadata: Optional[Dict] = None):
        """
        Register a new speaker profile
        
        Args:
            name: Speaker name
            embedding: Speaker embedding
            metadata: Optional metadata dictionary
        """
        from datetime import datetime
        
        profile_data = {
            'embedding': embedding.tolist(),
            'created_at': datetime.now().isoformat(),
            'metadata': metadata or {}
        }
        
        self.profile_registry.setdefault('profiles', {})[name] = profile_data
        save_profile_registry(self.profile_registry)
        
        logger.info(f"Registered speaker: {name}")
    
    def auto_assign_speaker(self, embedding: np.ndarray) -> Tuple[str, float]:
        """
        Automatically assign a speaker name (either existing or new voice_XX)
        
        Args:
            embedding: Speaker embedding
            
        Returns:
            Tuple of (speaker_name, confidence_score)
        """
        # First check if it's the narrator
        is_narrator, narrator_score = self.is_narrator(embedding)
        if is_narrator:
            return config.NARRATOR_DEFAULT_NAME, narrator_score
        
        # Check against existing speakers
        speaker_name, score = self.identify_speaker(embedding)
        if speaker_name:
            return speaker_name, score
        
        # Create new speaker profile
        new_name = get_next_voice_name(self.profile_registry)
        self.register_speaker(new_name, embedding, {'auto_discovered': True})
        
        logger.info(f"Discovered new speaker: {new_name}")
        return new_name, 1.0  # High confidence for new speaker
    
    def cluster_speakers(self, embeddings: List[np.ndarray], 
                        min_samples: int = 2) -> List[int]:
        """
        Cluster embeddings to discover speakers
        
        Args:
            embeddings: List of speaker embeddings
            min_samples: Minimum samples for a cluster
            
        Returns:
            List of cluster labels
        """
        if len(embeddings) < min_samples:
            return list(range(len(embeddings)))
        
        # Convert to array
        X = np.array(embeddings)
        
        # Use DBSCAN for clustering
        # eps is the maximum distance between samples
        eps = 1 - config.CLUSTERING_THRESHOLD  # Convert similarity to distance
        
        clustering = DBSCAN(
            eps=eps,
            min_samples=min_samples,
            metric='cosine'
        ).fit(X)
        
        labels = clustering.labels_
        n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
        
        logger.info(f"Discovered {n_clusters} speaker clusters from {len(embeddings)} samples")
        
        return labels.tolist()
    
    def get_speaker_stats(self) -> Dict:
        """
        Get statistics about registered speakers
        
        Returns:
            Dictionary with speaker statistics
        """
        profiles = self.profile_registry.get('profiles', {})
        
        stats = {
            'total_speakers': len(profiles),
            'has_narrator': config.NARRATOR_DEFAULT_NAME in profiles,
            'speakers': list(profiles.keys())
        }
        
        return stats
    
    def update_narrator_profile(self, embeddings: List[np.ndarray], name: Optional[str] = None):
        """
        Create or update narrator profile from multiple samples
        
        Args:
            embeddings: List of narrator embeddings
            name: Optional custom name (defaults to config.NARRATOR_DEFAULT_NAME)
        """
        if not embeddings:
            raise ValueError("No embeddings provided")
        
        # Average the embeddings
        avg_embedding = np.mean(embeddings, axis=0)
        
        # Calculate consistency (average pairwise similarity)
        similarities = []
        for i in range(len(embeddings)):
            for j in range(i + 1, len(embeddings)):
                sim = self.calculate_similarity(embeddings[i], embeddings[j])
                similarities.append(sim)
        
        consistency = np.mean(similarities) if similarities else 1.0
        
        speaker_name = name or config.NARRATOR_DEFAULT_NAME
        
        metadata = {
            'num_samples': len(embeddings),
            'consistency_score': float(consistency),
            'is_narrator': True
        }
        
        self.register_speaker(speaker_name, avg_embedding, metadata)
        
        logger.info(f"Updated narrator profile: {speaker_name} "
                   f"({len(embeddings)} samples, consistency: {consistency:.3f})")
        
        return consistency
    
    def delete_speaker(self, name: str):
        """
        Delete a speaker profile
        
        Args:
            name: Speaker name to delete
        """
        if name in self.profile_registry.get('profiles', {}):
            del self.profile_registry['profiles'][name]
            save_profile_registry(self.profile_registry)
            logger.info(f"Deleted speaker: {name}")
        else:
            logger.warning(f"Speaker not found: {name}")
    
    def rename_speaker(self, old_name: str, new_name: str):
        """
        Rename a speaker
        
        Args:
            old_name: Current speaker name
            new_name: New speaker name
        """
        profiles = self.profile_registry.get('profiles', {})
        
        if old_name not in profiles:
            logger.warning(f"Speaker not found: {old_name}")
            return
        
        if new_name in profiles:
            logger.warning(f"Speaker already exists: {new_name}")
            return
        
        profiles[new_name] = profiles.pop(old_name)
        save_profile_registry(self.profile_registry)
        
        logger.info(f"Renamed speaker: {old_name} -> {new_name}")


# ============================================================================
# CONVENIENCE FUNCTIONS
# ============================================================================

def extract_speaker_embedding(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """
    Convenience function to extract speaker embedding
    
    Args:
        audio: Audio data as numpy array
        sample_rate: Sample rate in Hz
        
    Returns:
        Speaker embedding vector
    """
    recognizer = SpeakerRecognition()
    return recognizer.extract_embedding(audio, sample_rate)
