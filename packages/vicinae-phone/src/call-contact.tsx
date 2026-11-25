import { useEffect, useState } from "react";
import {
	Action,
	ActionPanel,
	Icon,
	List,
	Toast,
	closeMainWindow,
	showToast,
} from "@vicinae/api";
import { type Contact, call, contacts, looksLikeNumber, matches } from "./phone";

async function dial(number: string, who?: string) {
	try {
		await call(number);
		await closeMainWindow();
		await showToast({ style: Toast.Style.Success, title: `Calling ${who ?? number}` });
	} catch (error) {
		await showToast({ style: Toast.Style.Failure, title: "Could not call", message: String((error as Error).message ?? error) });
	}
}

export default function CallContact() {
	const [all, setAll] = useState<Contact[]>([]);
	const [loading, setLoading] = useState(true);
	const [query, setQuery] = useState("");

	useEffect(() => {
		contacts()
			.then(setAll)
			.catch((error) =>
				showToast({ style: Toast.Style.Failure, title: "Could not read contacts", message: String(error) }),
			)
			.finally(() => setLoading(false));
	}, []);

	const shown = all.filter((c) => matches(c, query));

	return (
		<List
			isLoading={loading}
			filtering={false}
			onSearchTextChange={setQuery}
			searchBarPlaceholder="Name or number"
		>
			{looksLikeNumber(query) && (
				<List.Item
					title={`Call ${query.trim()}`}
					icon={Icon.Phone}
					actions={
						<ActionPanel>
							<Action title="Call" icon={Icon.Phone} onAction={() => dial(query.trim())} />
						</ActionPanel>
					}
				/>
			)}
			{shown.map((c) => (
				<List.Item
					key={`${c.name}\t${c.number}`}
					title={c.name}
					subtitle={c.number}
					icon={Icon.Person}
					accessories={[{ text: c.label }]}
					actions={
						<ActionPanel>
							<Action title={`Call ${c.number}`} icon={Icon.Phone} onAction={() => dial(c.number, c.name)} />
							<Action.CopyToClipboard title="Copy Number" content={c.number} />
						</ActionPanel>
					}
				/>
			))}
			{!loading && all.length === 0 && (
				<List.EmptyView
					title="No contacts"
					description="Turn on Contacts synchronizer in KDE Connect on the phone, or type a number."
				/>
			)}
		</List>
	);
}
