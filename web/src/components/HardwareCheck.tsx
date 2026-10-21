import { useState, useEffect, useCallback } from "react";
import { Button } from "@/components/ui/button";
import {
  CheckCircle2,
  XCircle,
  RefreshCw,
  Mic,
  Volume2,
  Wifi,
} from "lucide-react";

interface HardwareCheckProps {
  onStart: () => void;
}

type CheckStatus = "idle" | "checking" | "passed" | "failed";

export default function HardwareCheck({ onStart }: HardwareCheckProps) {
  const [netStatus, setNetStatus] = useState<CheckStatus>("idle");
  const [micStatus, setMicStatus] = useState<CheckStatus>("idle");
  const [audioStatus, setAudioStatus] = useState<CheckStatus>("idle");
  const [latencyMs, setLatencyMs] = useState<number | null>(null);

  // 1. Tes Koneksi Internet dengan Timeout & AbortController (Mencegah Infinite Loop & Hanging)
  const checkInternet = useCallback(async (): Promise<boolean> => {
    setNetStatus("checking");
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 4000); // 4 detik timeout

    try {
      const startTime = performance.now();
      // Panggil endpoint health check API lokal
      const response = await fetch("http://localhost:3001/api/v1/health", {
        signal: controller.signal,
        cache: "no-store",
      });
      clearTimeout(timeoutId);

      if (response.ok) {
        const endTime = performance.now();
        setLatencyMs(Math.round(endTime - startTime));
        setNetStatus("passed");
        return true;
      }
      setNetStatus("failed");
      return false;
    } catch {
      setNetStatus("failed");
      return false;
    }
  }, []);

  // 2. Tes Mikrofon (Audio Input Permission)
  const checkMicrophone = useCallback(async (): Promise<boolean> => {
    setMicStatus("checking");
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      // Matikan track audio segera setelah tes berhasil agar indikator mic tidak terus aktif
      stream.getTracks().forEach((track) => track.stop());
      setMicStatus("passed");
      return true;
    } catch {
      setMicStatus("failed");
      return false;
    }
  }, []);

  // 3. Tes Output Audio Speaker
  const checkAudioOutput = useCallback(async (): Promise<boolean> => {
    setAudioStatus("checking");
    try {
      if (typeof window !== "undefined" && "AudioContext" in window) {
        const ctx = new (
          window.AudioContext ||
          (window as unknown as { webkitAudioContext: typeof AudioContext })
            .webkitAudioContext
        )();
        await ctx.resume();
        await ctx.close();
      }
      setAudioStatus("passed");
      return true;
    } catch {
      setAudioStatus("failed");
      return false;
    }
  }, []);

  // 4. Runner Master yang Mengeksekusi Seluruh Pengecekan
  const runAllChecks = useCallback(async () => {
    // Reset status sebelum memulai ulang
    setNetStatus("checking");
    setMicStatus("idle");
    setAudioStatus("idle");

    const netOk = await checkInternet();
    const micOk = await checkMicrophone();
    const audioOk = await checkAudioOutput();

    if (!netOk || !micOk || !audioOk) {
      console.warn("Hardware check partially failed.");
    }
  }, [checkInternet, checkMicrophone, checkAudioOutput]);

  // Jalankan HANYA sekali saat komponen di-mount
  useEffect(() => {
    runAllChecks();
  }, [runAllChecks]);

  const allPassed =
    netStatus === "passed" &&
    micStatus === "passed" &&
    audioStatus === "passed";
  const isChecking =
    netStatus === "checking" ||
    micStatus === "checking" ||
    audioStatus === "checking";

  return (
    <div className="space-y-4 border rounded-lg p-4 bg-card text-card-foreground">
      <h3 className="text-sm font-medium text-foreground mb-3">
        System & Hardware Readiness
      </h3>

      {/* Item 1: Internet Connection */}
      <div className="flex items-center justify-between text-sm py-1.5 border-b">
        <div className="flex items-center gap-2">
          <Wifi className="h-4 w-4 text-muted-foreground" />
          <span>Internet Connection</span>
        </div>
        <div>
          {netStatus === "checking" && (
            <span className="text-xs text-muted-foreground animate-pulse">
              Checking...
            </span>
          )}
          {netStatus === "passed" && (
            <span className="text-xs text-green-600 font-medium flex items-center gap-1">
              <CheckCircle2 className="h-3.5 w-3.5" /> Passed ({latencyMs} ms)
            </span>
          )}
          {netStatus === "failed" && (
            <span className="text-xs text-red-600 font-medium flex items-center gap-1">
              <XCircle className="h-3.5 w-3.5" /> Connection Failed
            </span>
          )}
        </div>
      </div>

      {/* Item 2: Microphone */}
      <div className="flex items-center justify-between text-sm py-1.5 border-b">
        <div className="flex items-center gap-2">
          <Mic className="h-4 w-4 text-muted-foreground" />
          <span>Microphone Access</span>
        </div>
        <div>
          {micStatus === "idle" && (
            <span className="text-xs text-muted-foreground">Waiting...</span>
          )}
          {micStatus === "checking" && (
            <span className="text-xs text-muted-foreground animate-pulse">
              Checking...
            </span>
          )}
          {micStatus === "passed" && (
            <span className="text-xs text-green-600 font-medium flex items-center gap-1">
              <CheckCircle2 className="h-3.5 w-3.5" /> Ready
            </span>
          )}
          {micStatus === "failed" && (
            <span className="text-xs text-red-600 font-medium flex items-center gap-1">
              <XCircle className="h-3.5 w-3.5" /> Permission Denied
            </span>
          )}
        </div>
      </div>

      {/* Item 3: Audio Output */}
      <div className="flex items-center justify-between text-sm py-1.5">
        <div className="flex items-center gap-2">
          <Volume2 className="h-4 w-4 text-muted-foreground" />
          <span>Speaker Output</span>
        </div>
        <div>
          {audioStatus === "idle" && (
            <span className="text-xs text-muted-foreground">Waiting...</span>
          )}
          {audioStatus === "checking" && (
            <span className="text-xs text-muted-foreground animate-pulse">
              Checking...
            </span>
          )}
          {audioStatus === "passed" && (
            <span className="text-xs text-green-600 font-medium flex items-center gap-1">
              <CheckCircle2 className="h-3.5 w-3.5" /> Ready
            </span>
          )}
          {audioStatus === "failed" && (
            <span className="text-xs text-red-600 font-medium flex items-center gap-1">
              <XCircle className="h-3.5 w-3.5" /> Audio Error
            </span>
          )}
        </div>
      </div>

      {/* Action Buttons */}
      <div className="pt-2 flex gap-2">
        {!allPassed && (
          <Button
            type="button"
            variant="outline"
            className="w-full"
            onClick={runAllChecks} // Menghubungkan onClick ke runner master
            disabled={isChecking}
          >
            <RefreshCw
              className={`h-4 w-4 mr-2 ${isChecking ? "animate-spin" : ""}`}
            />
            Retry Check
          </Button>
        )}

        <Button
          type="button"
          className="w-full"
          disabled={!allPassed || isChecking}
          onClick={onStart}
        >
          Start Interview
        </Button>
      </div>
    </div>
  );
}
