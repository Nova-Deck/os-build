import { Dropdown, Field, PanelSectionRow, SliderField, ToggleField } from "@decky/ui";
import type { ReactNode } from "react";
import type { DropdownChoice } from "../types";

type Option = string | DropdownChoice;

/* A labelled row is Field + Dropdown, NEVER DropdownItemInternal. Both come from @decky/ui, but
   they are found in Valve's bundle by very different means: Dropdown matches on the class
   (prototype.SetSelectedOption && prototype.BuildMenu), while DropdownItemInternal is matched by
   REGEX over the minified mod.toString(), looking for the literal prop names "dropDownControlRef"
   and "description". A client-side rename makes that scrape resolve to the wrong module or to
   undefined, and what lands in Game Mode carries no working gamepad focus handlers -- the panel
   freezes on the first dropdown the stick reaches. Nothing fails at build time. The label sits
   ABOVE the control (childrenLayout="below") as a consequence; that is the cost of the sturdy
   lookup, not a design choice. */
export function SelectEdit({ label, value, options, onChange, disabled }: {
  label?: ReactNode;
  value: any;
  options: Option[];
  onChange: (data: any) => void;
  disabled?: boolean;
}) {
  const rgOptions = options.map((option) => (typeof option === "string" ? { data: option, label: option } : option));
  return (
    <PanelSectionRow>
      {label === undefined ? (
        <div className="novadeck-bare-dropdown">
          <Dropdown disabled={disabled} selectedOption={value} rgOptions={rgOptions} onChange={(option) => onChange(option.data)} />
        </div>
      ) : (
        <Field label={label} childrenLayout="below" childrenContainerWidth="max" disabled={disabled}>
          <Dropdown disabled={disabled} selectedOption={value} rgOptions={rgOptions} onChange={(option) => onChange(option.data)} />
        </Field>
      )}
    </PanelSectionRow>
  );
}

export function ToggleRow({ label, value, onChange, disabled, description }: {
  label: ReactNode;
  value: any;
  onChange: (value: boolean) => void;
  disabled?: boolean;
  description?: ReactNode;
}) {
  return (
    <PanelSectionRow>
      <ToggleField label={label} description={description} checked={!!value} disabled={disabled} onChange={onChange} />
    </PanelSectionRow>
  );
}

export function SliderEdit({ label, value, min, max, step, onChange, disabled }: {
  label: ReactNode;
  value: any;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  disabled?: boolean;
}) {
  const numeric = Number(value);
  return (
    <PanelSectionRow>
      <div className="novadeck-slider-field">
        <SliderField
          label={label}
          value={Number.isFinite(numeric) ? numeric : min}
          min={min}
          max={max}
          step={step}
          showValue
          disabled={disabled}
          onChange={onChange}
        />
      </div>
    </PanelSectionRow>
  );
}
