import { Dropdown, DropdownItemInternal, Field, PanelSectionRow, SliderField, ToggleField } from "@decky/ui";
import type { ReactNode } from "react";
import type { DropdownChoice } from "../types";

type Option = string | DropdownChoice;

export function SelectEdit({ label, value, options, onChange, labelBelow, disabled }: {
  label?: ReactNode;
  value: any;
  options: Option[];
  onChange: (data: any) => void;
  labelBelow?: boolean;
  disabled?: boolean;
}) {
  const rgOptions = options.map((option) => (typeof option === "string" ? { data: option, label: option } : option));
  return (
    <PanelSectionRow>
      {label === undefined ? (
        <div className="novadeck-bare-dropdown">
          <Dropdown disabled={disabled} selectedOption={value} rgOptions={rgOptions} onChange={(option) => onChange(option.data)} />
        </div>
      ) : labelBelow ? (
        <Field label={label} childrenLayout="below" childrenContainerWidth="max" disabled={disabled}>
          <Dropdown disabled={disabled} selectedOption={value} rgOptions={rgOptions} onChange={(option) => onChange(option.data)} />
        </Field>
      ) : (
        <DropdownItemInternal disabled={disabled} childrenContainerWidth="max" label={label} selectedOption={value} rgOptions={rgOptions} onChange={(option) => onChange(option.data)} />
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
