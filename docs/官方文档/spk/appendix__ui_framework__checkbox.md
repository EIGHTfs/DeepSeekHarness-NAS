---
source: https://help.synology.com/developer-guide/appendix/ui_framework/checkbox.html
title: Checkbox
fetched: 2026-09-11
---

# Checkbox

## Template

`<v-checkbox />`

## Checkbox API

### Checkbox - Props

``

``

****

****
**

****

****

``

````

| Prop name | Description | Type | Values | Default |
|---|---|---|---|---|
| subscribeField | Subscribe specific register-key form-item on ancestor | string | - | void 0 |
| activeFormItem | do not register on form-item | boolean | - | true |
| enterKey | used for enterkeyhint attribute, and will change behavior when enter key is pressed | string | - | EnterHint.Enter |
| boundaryComponentName | - | string | - | 'PortalTarget' |
| iconType | - | string | - | ICON_TYPE.FOLLOW_MANAGER |
| stopPropagation | If true, the click event of the checkbox will stop propagation. | boolean | - | false |
| v-model | If true, the status of the checkbox will be checked.Note: Only if indeterminate is false | boolean | - | false |
| indeterminate | If true, the status of the checkbox will always be indeterminate state. | boolean | - | false |
| disabled | If true, the checkbox will be disabled. | boolean | - | false |
| id | ID of the checkbox. | string | - | function() { return syno-${this.uuid};} |
| ariaLabelledby | - | string | - | function() { return this.id; } |
| name | Name of the checkbox. | string | - | void 0 |
| labelColor | Color of label | string | 'normal', 'red' | 'normal' |

### Checkbox - Methods

### onChange

Dispatch an event (form.change), first triggering it on the instance itself,
and then propagates upward along the parent chain until finding the FormItem.

| Param name | Type | Description |
|---|---|---|
| event | - | - |

### onBlurInput

Dispatch an event (form.blur), first triggering it on the instance itself,
and the propagates upward along the parent chain until finding the FormItem.

### onClick

If disabled is false, run onChange function.

| Param name | Type | Description |
|---|---|---|
| e | - | - |

### Checkbox - Events

****``

****``

****``
****``

****``

| Event name | Properties | Description |
|---|---|---|
| focus-next-field | - | - |
| focus-prev-field | - | - |
| blur | component this - the checkbox instance | Emitted when checkbox is blurred. |
| input | checked Boolean - the check state of the checkbox | Emitted when checked state change. |
| change | val Boolean - the check state of the checkboxevt EventObject - the change event object | Emitted when checked state change. |
| focus | component this - the checkbox instance | Emitted when checkbox is focused. |

### Checkbox - Slots

| Name | Description | Bindings |
|---|---|---|
| default | Embed default slot to show checkbox label | - |
