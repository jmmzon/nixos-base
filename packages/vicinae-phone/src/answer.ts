import { Toast, showHUD, showToast } from "@vicinae/api";
import { call } from "./phone";

export default async function () {
	try {
		await call("answer");
		await showHUD("Call answered");
	} catch (error) {
		await showToast({ style: Toast.Style.Failure, title: "Could not answer", message: String((error as Error).message ?? error) });
	}
}
