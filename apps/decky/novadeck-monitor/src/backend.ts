import { call } from "@decky/api";
import type { Telemetry } from "./types";

export const getTelemetry = () => call<[], Telemetry>("get_telemetry");
export const getOsVersion = () => call<[], string>("get_os_version");
