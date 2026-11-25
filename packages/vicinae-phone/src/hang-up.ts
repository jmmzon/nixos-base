import { Toast, showHUD, showToast } from "@vicinae/api";
import { call } from "./phone";

export default async function () {
	try {
		await call("hangup");
		await showHUD("Call ended");
	} catch (error) {
		await showToast({ style: Toast.Style.Failure, title: "Could not hang up", message: String((error as Error).message ?? error) });
	}
}
