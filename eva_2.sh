#!/bin/bash

# OpenRouter API Configuration
API_KEY="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"
MODEL="meta-llama/llama-3.3-70b-instruct:free"
API_URL="https://openrouter.ai/api/v1/chat/completions"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
PROJECT_DIR=""
TOTAL_SCORE=0
FILES_TO_CHECK=()
DIFFICULTY=""
NUM_QUESTIONS=0

# Function to send message to AI
ask_ai() {
	local prompt="$1"
	local system_msg="$2"

	local messages="[]"
	if [ -n "$system_msg" ]; then
		messages=$(echo "$messages" | jq --arg msg "$system_msg" '. += [{"role": "system", "content": $msg}]')
	fi
	messages=$(echo "$messages" | jq --arg msg "$prompt" '. += [{"role": "user", "content": $msg}]')

	local request_body=$(jq -n \
		--arg model "$MODEL" \
		--argjson messages "$messages" \
		'{
            "model": $model,
            "messages": $messages
        }')

	local response=$(curl -s "$API_URL" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $API_KEY" \
		-d "$request_body")

	echo "$response" | jq -r '.choices[0].message.content'
}

# Function to check norminette
check_norminette() {
	echo -e "${CYAN}========================================${NC}"
	echo -e "${CYAN}   STEP 1: Checking Norminette...${NC}"
	echo -e "${CYAN}========================================${NC}\n"

	if ! command -v norminette &>/dev/null; then
		echo -e "${YELLOW}Warning: norminette not found. Skipping norm check.${NC}\n"
		return 0
	fi

	local norm_output=$(norminette "$PROJECT_DIR" 2>&1)
	echo "$norm_output"
	echo

	if echo "$norm_output" | grep -qi "Error"; then
		echo -e "${RED}╔════════════════════════════════════════╗${NC}"
		echo -e "${RED}║          EVALUATION FAILED             ║${NC}"
		echo -e "${RED}║              GRADE: 0/100              ║${NC}"
		echo -e "${RED}╚════════════════════════════════════════╝${NC}\n"
		echo -e "${RED}Reason: Norminette errors detected.${NC}"
		echo -e "${RED}You must fix all norm errors before evaluation.${NC}\n"
		exit 1
	fi

	echo -e "${GREEN}✓ Norminette passed! Proceeding to code evaluation...${NC}\n"
	return 0
}

# Function to find C files
find_c_files() {
	echo -e "${CYAN}Finding C files in project...${NC}\n"

	while IFS= read -r -d '' file; do
		FILES_TO_CHECK+=("$file")
	done < <(find "$PROJECT_DIR" -name "*.c" -type f -print0)

	if [ ${#FILES_TO_CHECK[@]} -eq 0 ]; then
		echo -e "${RED}No C files found in the project directory.${NC}"
		exit 1
	fi

	echo -e "${GREEN}Found ${#FILES_TO_CHECK[@]} C file(s) to evaluate:${NC}"
	for file in "${FILES_TO_CHECK[@]}"; do
		echo -e "  - ${BLUE}$file${NC}"
	done
	echo
}

# Function to evaluate a single file
evaluate_file() {
	local file="$1"
	local file_num="$2"
	local total_files="$3"

	echo -e "${CYAN}========================================${NC}"
	echo -e "${CYAN}   File [$file_num/$total_files]: $(basename "$file")${NC}"
	echo -e "${CYAN}========================================${NC}\n"

	# Read file content
	local file_content=$(cat "$file")

	# Difficulty-specific guidance
	local difficulty_rules=""
	case "$DIFFICULTY" in
		low)
			difficulty_rules="- Keep questions simple and practical.
- Focus on basic flow, function roles, and straightforward edge cases.
- Avoid deep pointer arithmetic, undefined behavior, or heavy optimization topics."
			;;
		medium)
			difficulty_rules="- Balance practical and technical depth.
- Include some memory/pointer handling, error paths, and non-trivial edge cases.
- Ask about trade-offs and specific lines/branches."
			;;
		hard)
			difficulty_rules="- Dive deep into invariants, complexity, lifetimes, aliasing, undefined behavior, and optimization.
- Reference exact lines/snippets and 'what happens if' scenarios.
- Explore alternative designs and tricky edge cases."
			;;
	esac

	# Enhanced AI prompt for generating questions
	local ai_prompt="You are an experienced 42 coding school evaluator conducting a code defense session. Your goal is to verify the student's authorship and deep understanding of their submitted code through targeted questioning.

Context:
- File: $file
- Difficulty: $(echo "$DIFFICULTY" | tr '[:lower:]' '[:upper:]')

Code:
\`\`\`c
$file_content
\`\`\`

Task:
Generate exactly $NUM_QUESTIONS probing questions tailored to the selected difficulty.

Difficulty guidance:
$difficulty_rules

Question requirements:
- Make questions specific to THIS code (reference function names, variables, branches, or exact logic).
- Probe algorithmic decisions, implementation details, edge cases, C fundamentals, and optimization trade-offs, tuned to the chosen difficulty.
- Avoid generic questions that fit any code.
- Keep wording concise and clear.
- Do NOT reference any source code line numbers or ranges (e.g., 'on line 64', 'lines 31-35'). Refer by identifiers or quote short code fragments instead.

Output:
Return ONLY $NUM_QUESTIONS questions, numbered 1..$NUM_QUESTIONS (e.g., '1. ...'), one per line. No preamble or extra text. Do not mention any line numbers or ranges."

	echo -e "${YELLOW}AI is analyzing the code...${NC}\n"
	local questions=$(ask_ai "$ai_prompt")

	# Fallback: if AI mentioned line numbers/ranges, regenerate once with stricter system guidance
	if echo "$questions" | grep -Eiq '\b(on[[:space:]]*)?lines?\b[[:space:]]*[0-9]'; then
		local strict_system="You must not mention any line numbers or line ranges. Regenerate exactly $NUM_QUESTIONS concise questions following the prompt constraints. Do not add preamble."
		questions=$(ask_ai "$ai_prompt" "$strict_system")
	fi

	echo -e "${GREEN}Generated Questions:${NC}"
	echo -e "${BLUE}$questions${NC}\n"

	# Collect student answers
	local answers=""
	local question_num=1

	while IFS= read -r line; do
		if [[ $line =~ ^[0-9]+\. ]]; then
			echo -e "${CYAN}$line${NC}"
			echo -ne "${YELLOW}Your answer (or 'skip' to skip): ${NC}"
			answer=""
			IFS= read -r answer </dev/tty

			# Check if answer is empty
			if [ -z "$answer" ]; then
				echo -e "\n${RED}╔════════════════════════════════════════╗${NC}"
				echo -e "${RED}║          EVALUATION FAILED             ║${NC}"
				echo -e "${RED}║              GRADE: 0/100              ║${NC}"
				echo -e "${RED}╚════════════════════════════════════════╝${NC}\n"
				echo -e "${RED}Reason: Empty answer detected for file: $(basename "$file")${NC}"
				echo -e "${RED}This indicates potential cheating or lack of understanding.${NC}\n"
				exit 1
			fi

			# Allow skipping questions but still record them
			if [[ "$answer" == "skip" ]]; then
				answers+="Q$question_num: $line\nA$question_num: [Student chose to skip this question]\n\n"
			else
				answers+="Q$question_num: $line\nA$question_num: $answer\n\n"
			fi

			question_num=$((question_num + 1))
			echo
		fi
	done <<<"$questions"

	# Ask AI to evaluate answers
	local eval_prompt="You are evaluating a 42 school student's understanding of their code.

Original code from file: $file
\`\`\`c
$file_content
\`\`\`

Questions and Answers:
$answers

Analyze if the student truly understands this code or if they likely cheated. Consider:
- Answer accuracy and depth
- Technical understanding
- Consistency with the code
- Ability to explain design decisions
- handle the langauge the student used to answer
Respond with ONLY ONE WORD:
- 'PASS' if they clearly understand their code
- 'CHEAT' if they don't understand (indicating cheating)

Then on a new line, give a brief reason (max 2 sentences)."

	echo -e "${YELLOW}AI is evaluating your answers...${NC}\n"
	local evaluation=$(ask_ai "$eval_prompt")

	local result=$(echo "$evaluation" | head -n1 | tr '[:lower:]' '[:upper:]')
	local reason=$(echo "$evaluation" | tail -n +2)

	if [[ "$result" == *"CHEAT"* ]]; then
		echo -e "\n${RED}╔════════════════════════════════════════╗${NC}"
		echo -e "${RED}║          EVALUATION FAILED             ║${NC}"
		echo -e "${RED}║              GRADE: 0/100              ║${NC}"
		echo -e "${RED}╚════════════════════════════════════════╝${NC}\n"
		echo -e "${RED}Reason: Suspected cheating detected in file: $(basename "$file")${NC}"
		echo -e "${RED}$reason${NC}\n"
		exit 1
	fi

	echo -e "${GREEN}✓ File evaluation passed!${NC}"
	echo -e "${GREEN}Reason: $reason${NC}\n"
}

# Main evaluation function
main() {
	echo -e "${CYAN}"
	echo "╔════════════════════════════════════════════════╗"
	echo "║                                                ║"
	echo "║        42 SCHOOL AI EVALUATOR v1.0             ║"
	echo "║                                                ║"
	echo "╔════════════════════════════════════════════════╗"
	echo -e "${NC}\n"

	# Get project directory
	echo -ne "${YELLOW}Enter project directory path: ${NC}"
	read -r PROJECT_DIR

	if [ ! -d "$PROJECT_DIR" ]; then
		echo -e "${RED}Error: Directory does not exist.${NC}"
		exit 1
	fi

	# Choose difficulty
	while true; do
		echo -ne "${YELLOW}Choose question difficulty (low/medium/hard): ${NC}"
		read -r DIFFICULTY
		DIFFICULTY=$(echo "$DIFFICULTY" | tr '[:upper:]' '[:lower:]')
		# accept common typo
		if [ "$DIFFICULTY" = "meduim" ]; then DIFFICULTY="medium"; fi
		case "$DIFFICULTY" in
			low) NUM_QUESTIONS=5; break ;;
			medium) NUM_QUESTIONS=6; break ;;
			hard) NUM_QUESTIONS=8; break ;;
			*) echo -e "${YELLOW}Please enter 'low', 'medium', or 'hard'.${NC}" ;;
		esac
	done
	echo -e "${GREEN}✓ Difficulty set to '${DIFFICULTY}' with $NUM_QUESTIONS questions per file.${NC}\n"

	# Step 1: Check norminette
	check_norminette

	# Step 2: Find C files
	find_c_files

	echo -ne "${YELLOW}Press ENTER to start the evaluation...${NC}"
	read -r
	echo

	# Step 3: Evaluate each file
	local file_count=0
	for file in "${FILES_TO_CHECK[@]}"; do
		file_count=$((file_count + 1))
		evaluate_file "$file" "$file_count" "${#FILES_TO_CHECK[@]}"
	done

	# Final success message
	echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║                                                ║${NC}"
	echo -e "${GREEN}║         🎉 EVALUATION SUCCESSFUL! 🎉           ║${NC}"
	echo -e "${GREEN}║                                                ║${NC}"
	echo -e "${GREEN}║              GRADE: 100/100                    ║${NC}"
	echo -e "${GREEN}║                                                ║${NC}"
	echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}\n"

	# Generate final comment from AI
	local final_prompt="Generate a short, encouraging message (2-3 sentences) for a 42 school student who successfully passed their code evaluation and demonstrated excellent understanding of their work."

	echo -e "${YELLOW}Generating final feedback...${NC}\n"
	local final_message=$(ask_ai "$final_prompt")

	echo -e "${CYAN}Evaluator's Comment:${NC}"
	echo -e "${GREEN}$final_message${NC}\n"
}

# Run main function
main
