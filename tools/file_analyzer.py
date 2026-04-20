import os
import re
from typing import List, Dict

def file_analyzer(directory_path: str, pattern: str) -> List[Dict[str, str]]:
    """
    Analyzes all files within a specified directory recursively for a given regex pattern.

    Args:
        directory_path: The root directory to search.
        pattern: The regex pattern to search for.

    Returns:
        A list of dictionaries, where each dictionary contains the file path 
        and all matches found.
    """
    results = []
    compiled_pattern = re.compile(pattern)
    
    if not os.path.isdir(directory_path):
        return [{"error": f"Directory not found: {directory_path}"}]

    for root, _, files in os.walk(directory_path):
        for file_name in files:
            file_path = os.path.join(root, file_name)
            matches = []
            try:
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    # Find all matches
                    for match in compiled_pattern.finditer(content):
                        matches.append(match.group(0))
                
                if matches:
                    results.append({
                        "file_path": file_path,
                        "matches": matches,
                        "count": len(matches)
                    })
            except Exception as e:
                # Handle unreadable files or permission errors gracefully
                print(f"Skipping {file_path} due to error: {e}")
                continue
    
    return results

# Example Usage (for testing):
# print(file_analyzer("./app/memory", r"self_model\.toon"))