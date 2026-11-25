// Runs the `call` and `call-contacts` commands (my.bluetooth.phoneCalls).
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);
const BIN = "/run/current-system/sw/bin";

export type Contact = { name: string; label: string; number: string; folded: string };

// Lower case without accents; ł has no decomposition.
export function fold(text: string): string {
	return text
		.toLowerCase()
		.replace(/ł/g, "l")
		.normalize("NFKD")
		.replace(/\p{M}/gu, "");
}

export async function contacts(): Promise<Contact[]> {
	const { stdout } = await run(`${BIN}/call-contacts`, [], { maxBuffer: 4 << 20 });
	return stdout
		.split("\n")
		.filter((line) => line.trim() !== "")
		.map((line) => {
			const [name = "", label = "", number = ""] = line.split("\t");
			return { name, label, number, folded: fold(name) };
		})
		.filter((c) => c.number !== "");
}

// Every word of the query must occur in the name.
export function matches(contact: Contact, query: string): boolean {
	return fold(query)
		.split(/\s+/)
		.filter(Boolean)
		.every((word) => contact.folded.includes(word));
}

export function looksLikeNumber(text: string): boolean {
	const compact = text.replace(/[\s\-().\/]/g, "");
	return /^\+?[0-9*#]{3,}$/.test(compact);
}

// `call ARGS...`; rejects with the command's message on failure.
export async function call(...args: string[]): Promise<void> {
	try {
		await run(`${BIN}/call`, args);
	} catch (error) {
		const stderr = (error as { stderr?: string }).stderr ?? "";
		throw new Error(stderr.replace(/^call: /, "").trim() || String(error));
	}
}
