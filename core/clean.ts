/**
 * voz's dictation cleanup pass: reads a raw transcript on stdin, prints the
 * cleaned text on stdout. Pure text transforms — no network, no LLM, nothing
 * leaves the machine. Installed to ~/.voz by scripts/setup-helper.sh; run with bun.
 *
 * Sources/Dictate/BasicCleaner.swift is the Swift twin — keep the pass order
 * and rules identical in both files.
 */

const FILLERS = new Set(["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mhm"]);

const NUMBER_WORDS = new Set([
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
  "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
  "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
  "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million",
]);

// Longest match first: two-word markers before single-word ones.
const MARKERS: string[][] = [
  ["no", "wait"], ["wait", "no"], ["i", "mean"], ["make", "that"],
  ["actually"], ["rather"],
];

/** Token without leading/trailing punctuation (keeps inner apostrophes). */
function core(token: string): string {
  return token.replace(/^[^\p{L}\p{N}']+|[^\p{L}\p{N}']+$/gu, "");
}

type Shape = "numeral" | "numberWord" | "capitalized" | "plain";

function shapeOf(token: string): Shape {
  const c = core(token);
  if (/^\d+$/.test(c)) return "numeral";
  if (NUMBER_WORDS.has(c.toLowerCase())) return "numberWord";
  if (/^\p{Lu}/u.test(c)) return "capitalized";
  return "plain";
}

function endsSentence(token: string): boolean {
  return /[.!?]$/.test(token);
}

function endsClause(token: string): boolean {
  return /[.,!?;:]$/.test(token);
}

// (a) "scratch that" drops everything back to the last sentence boundary.
function applyScratchThat(tokens: string[]): string[] {
  const out = [...tokens];
  let i = 0;
  while (i + 1 < out.length) {
    if (core(out[i]).toLowerCase() === "scratch" && core(out[i + 1]).toLowerCase() === "that") {
      let start = 0;
      for (let j = i - 1; j >= 0; j--) {
        if (endsSentence(out[j])) {
          start = j + 1;
          break;
        }
      }
      out.splice(start, i + 2 - start);
      i = start;
    } else {
      i++;
    }
  }
  return out;
}

// (b) "<A> <marker> <B>": when A and B share a shape, keep B, drop A + marker.
function applyCorrections(tokens: string[]): string[] {
  const out = [...tokens];
  let i = 1; // a correction needs a token A before the marker
  while (i < out.length) {
    const marker = MARKERS.find((words) =>
      words.every((w, k) => i + k < out.length && core(out[i + k]).toLowerCase() === w)
    );
    if (marker) {
      const bIndex = i + marker.length;
      if (bIndex < out.length && shapeOf(out[i - 1]) === shapeOf(out[bIndex])) {
        out.splice(i - 1, marker.length + 1);
        i = Math.max(1, i - 1);
        continue;
      }
    }
    i++; // unmatched markers stay
  }
  return out;
}

// (c) Standalone fillers, plus "you know" as a bare interjection.
function removeFillers(tokens: string[]): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < tokens.length) {
    const c = core(tokens[i]).toLowerCase();
    if (FILLERS.has(c)) {
      i++;
      continue;
    }
    if (c === "you" && i + 1 < tokens.length && core(tokens[i + 1]).toLowerCase() === "know") {
      // Bare = set off by punctuation or dangling at the end ("you know the
      // answer" must survive).
      const prev = out[out.length - 1];
      const bare = endsClause(tokens[i + 1]) || i + 2 === tokens.length ||
        (prev !== undefined && endsClause(prev));
      if (bare) {
        i += 2;
        continue;
      }
    }
    out.push(tokens[i]);
    i++;
  }
  return out;
}

// (d) Collapse immediate duplicate words ("like like" -> "like"); never across
// a sentence boundary ("stop. Stop" stays).
function collapseDuplicates(tokens: string[]): string[] {
  const out: string[] = [];
  for (const token of tokens) {
    const prev = out[out.length - 1];
    if (prev !== undefined && !endsSentence(prev) && core(prev) !== "" &&
        core(prev).toLowerCase() === core(token).toLowerCase()) {
      // Keep the first copy, unless the later one carries punctuation.
      if (endsClause(token)) out[out.length - 1] = token;
    } else {
      out.push(token);
    }
  }
  return out;
}

export function cleaned(raw: string): string {
  const trimmed = raw.trim();
  const first = trimmed.charAt(0);
  const startedUpper = first !== "" && first !== first.toLowerCase();
  let tokens = trimmed.split(/\s+/).filter((t) => t.length > 0);
  tokens = applyScratchThat(tokens);
  // Fillers go before corrections so "2 um actually 3" still corrects to "3".
  tokens = removeFillers(tokens);
  tokens = applyCorrections(tokens);
  tokens = collapseDuplicates(tokens);
  // (e) tidy: whitespace collapse comes free from the token join.
  let out = tokens.join(" ").replace(/\s+([.,!?;:])/g, "$1").trim();
  // Acceptance outputs stay lowercase: only capitalize when the raw text did.
  if (startedUpper && out !== "") out = out.charAt(0).toUpperCase() + out.slice(1);
  return out;
}

if (import.meta.main) {
  const raw = await new Response(Bun.stdin.stream()).text();
  process.stdout.write(cleaned(raw) + "\n");
}
