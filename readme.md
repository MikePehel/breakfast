# BreakFast - Advanced Break Pattern Tool for Renoise

BreakFast is a comprehensive Renoise tool designed for creating complex break patterns and rhythmic variations using symbolic notation and automated pattern generation. Transform sliced breakbeats into a complete library of patterns with precise timing control and flexible composition tools.

Special shout out to **erlsh** (https://github.com/dethine) from the TRACKERCORPS and Renoise Discord servers for their inspiration with their Snipper tool!

## Features

### Core Functions

#### Global Symbol Registry
- **Cross-Instrument Symbol Management**: Create and manage symbols across multiple instruments
- **Persistent Symbol Storage**: Symbols are saved and loaded automatically
- **Symbol Assignment**: Automatically assigns available symbols (A-T, 0-9) to instruments with breakpoints
- **Export/Import**: Full alphabet export/import in CSV and JSON formats for sharing and backup

#### Break Pattern Creation
- **Breakpoint Analysis**: Automatically analyzes phrases to identify break sections between user-defined breakpoints
- **Timing Preservation**: Maintains exact timing relationships, delays, and distances between notes
- **Pattern Stitching**: Seamlessly combines break sections with proper timing adjustments
- **Phrase Generation**: Creates new phrases from break string patterns

#### Range Selection Capture
- **Direct Pattern Capture**: Capture any selection from the pattern editor as a reusable symbol
- **Note Data Preservation**: Maintains note values, instrument assignments, delays, and effects
- **Cross-Pattern Placement**: Place captured patterns anywhere in your song
- **Intelligent Timing**: Automatically calculates proper spacing and timing for captured sequences

#### Advanced Symbol Editor
- **Visual Break Display**: Shows detailed information for each symbol including:
  - Line positions and timing
  - Instrument labels and assignments
  - Delay values in hexadecimal format
  - Source pattern and track information
- **Composite Symbols**: Create reusable pattern macros (U-Z) from base symbols
- **Break String Syntax**: Flexible pattern notation for complex arrangements
- **Real-time Validation**: Pattern syntax checking with error reporting

#### Flexible Placement System
- **Overflow Behaviors**:
  - **Extend**: Automatically extend pattern length to accommodate symbols
  - **Next Pattern**: Jump to next pattern when current is full
  - **Truncate**: Cut off notes that exceed pattern boundaries  
  - **Loop**: Wrap notes back to beginning of pattern
- **Overwrite Behaviors**:
  - **Sum**: Add notes to additional columns when conflicts occur
  - **Replace**: Clear entire symbol range before placing new notes
  - **Substitute**: Only replace notes on lines where new symbol has notes
  - **Retain**: Only place notes where no existing notes conflict
  - **Exclude**: Remove conflicting notes from both sources
  - **Intersect**: Keep only conflicting notes within symbol range

#### Instrument Source Control
- **Embedded Instrument**: Use instrument values from symbol definition
- **Current Selected**: Use currently selected instrument for all placements

### Slice Labeling System
- **Comprehensive Tagging**: Assign descriptive labels to slices (Kick, Snare, Hi-Hat, etc.)
- **Breakpoint Flags**: Mark slices that define section boundaries
- **Import/Export**: Save and share slice label configurations
- **Visual Interface**: User-friendly dialog for managing slice labels and breakpoints

## Usage

### Basic Workflow

1. **Prepare Your Source Material**
   - Load a sliced drum break or pattern into Renoise
   - Ensure you have at least one phrase containing your pattern

2. **Label Your Slices**
   - Open BreakFast from the Tools menu
   - Click "Label Slices" to open the labeling interface
   - Assign descriptive labels to each slice (Kick, Snare, Hi-Hat, etc.)
   - Set "Breakpoint" flags on slices that should define section boundaries
   - Save your labels

3. **Create Break Patterns**
   - Use the Symbol Editor to view your generated symbols
   - Each symbol (A, B, C, etc.) represents a break section
   - Create break strings using these symbols (e.g., "ABCBA", "AABAA")
   - Use composite symbols (U-Z) for complex pattern macros

4. **Place Patterns**
   - Use keyboard shortcuts to place symbols directly in the pattern editor
   - Configure overflow and overwrite behaviors to suit your workflow
   - Chain symbols together for complex arrangements

### Advanced Features

#### Range Selection Capture
```
1. Select any range in the pattern editor
2. Use "Capture Selection as BreakFast Symbol" from the context menu
3. The selection becomes available as a new symbol
4. Place the captured pattern anywhere using keyboard shortcuts
```

#### Break String Syntax
```
Basic Patterns:
ABCDE    - Sequential playback of all breaks
AABAA    - Repetition with variation
ABCBA    - Palindrome pattern

Composite Symbols:
U = ABC
V = CBA
Break String: UVUV    - Alternating forward/reverse patterns
```

#### Export/Import Alphabet
- **CSV Format**: Human-readable format for editing and analysis
- **JSON Format**: Complete metadata preservation for exact reconstruction
- **Cross-Project Sharing**: Share entire symbol libraries between songs

### Keybinding Setup
Configure keyboard shortcuts in Renoise Preferences > Keys > Global > Tools:
- **Insert Symbol A-T**: Direct placement of primary symbols
- **Insert Symbol 0-9**: Direct placement of numeric symbols  
- **Insert Composite U-Z**: Build break strings with composite symbols
- **Capture Selection**: Quickly capture pattern editor selections

### Performance Considerations
- Break pattern generation is optimized for real-time use
- Large numbers of breakpoints may affect UI responsiveness
- Overflow behaviors may create very long patterns - use truncate mode for performance
- Pattern editor selections are captured instantly with minimal CPU overhead

## Installation
1. Download the BreakFast tool files
2. Place them in your Renoise tools directory
3. Restart Renoise or use "Reload All Tools" from the Tools menu
4. Access BreakFast from Main Menu > Tools > BreakFast

## Technical Details
- **Timing Precision**: Uses 256-tick resolution for delay calculations
- **Symbol Capacity**: Supports 30 simultaneous symbols (A-T, 0-9)
- **Pattern Support**: Works with any pattern length and time signature
- **Data Persistence**: All symbols and labels saved automatically with tool preferences

---

*BreakFast transforms the way you work with breakbeats in Renoise, providing professional-grade tools for pattern manipulation and composition. Whether you're creating complex polyrhythms or simple variations, BreakFast gives you the precision and flexibility to realize your creative vision.*