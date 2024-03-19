--liquibase formatted sql

--changeset Nicolas Griesdorn 2e6dd4c3 stripComments:false runOnChange:true
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-10-19
				:
	Description	: SP used in CRM to void non paid or voided activation/airtime orders
				:
	NG20240307	: Refactored the report to allow Filling and Voiding of Activation and Airtime Orders
	NG20240310  : Added more error handling
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Fill_Void_ActivationAirtime_Orders]
    (
        @SessionID INT
        , @UserID INT
        , @Option INT
        , @OrderNo INT
    )
AS
BEGIN TRY
----Error Handling (Global)---------------------------------------------------------------------------------------------------------------
    IF ISNULL(@SessionID, 0) <> 2
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF NOT EXISTS (SELECT * FROM dbo.Order_No WHERE OrderType_ID IN (1, 9, 22, 23, 43, 44, 45, 46) AND Order_No = @OrderNo)
        RAISERROR ('This order number provided is not a fillable or voidable order type using this tool, please escalate to IT Support.', 12, 1);

    IF ISNULL(@OrderNo, 0) = 0 --NG20240310
        RAISERROR (
            'The order number provided is not a fillable or voidable order using this tool. Please double-check the order number, or escalate to IT Support', -- noqa: LT05
            12,
            1
        );
    --------------------------------------------------------------------------------------------------------------------------------------------
    ------View----------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 0
        BEGIN
            SELECT
                Onu.Order_No
                , Onu.Process
                , Onu.Filled
                , Onu.Paid
                , Onu.Void
                , Onu.DateFilled
                , o.Name
                , o.Price
                , o.DiscAmount
                , oNu.OrderTotal
                , o.SKU
            FROM dbo.Order_No AS Onu
            JOIN dbo.Orders AS o ON o.Order_No = Onu.Order_No
            WHERE
                Onu.Order_No = @OrderNo
                AND ISNULL(o.ParentItemID, 0) IN (0, 1)
        END;
    ------------------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 1
        BEGIN
            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Paid = 1 AND Order_No = @OrderNo)
                RAISERROR ('The order number provided is currently marked as Paid, please enter a non-Paid order number and try again.', 13, 1);
            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Process = 1 AND Filled = 1 AND Paid = 0 AND Void = 0 AND Order_No = @OrderNo) --NG20240310
                RAISERROR (
                    'The order number provided is currently already marked as filled, please enter a non-filled or void order number and try again.',
                    13,
                    1
                );

            UPDATE dbo.Order_No
            SET
                Process = 1
                , Filled = 1
                , Void = 0
                , DateFilled = GETDATE()
            WHERE Order_No = @OrderNo

            SELECT
                Onu.Order_No
                , Onu.Process
                , Onu.Filled
                , Onu.Paid
                , Onu.Void
                , Onu.DateFilled
                , o.Name
                , o.SKU
                , o.Price
                , o.DiscAmount
                , oNu.OrderTotal
                , 'This order has now been filled, please notify the Netsuite team so they can update NetSuite with the following Order Number:'
                + CAST(@OrderNo AS NVARCHAR(MAX))
                + '.' AS [Notify ERP]
            FROM dbo.Order_No AS Onu
            JOIN dbo.Orders AS o ON o.Order_No = Onu.Order_No
            WHERE
                Onu.Order_No = @OrderNo
                AND ISNULL(o.ParentItemID, 0) IN (0, 1)

        END;
    ----Void Activation/Airtime---------------------------------------------------------------------------------------------------------------
    IF @Option = 2
        BEGIN
            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Paid = 1 AND Order_No = @OrderNo)
                RAISERROR ('The order number provided is currently marked as Paid, please enter a non-Paid order number and try again.', 14, 1);
            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Void = 1 AND Order_No = @OrderNo) --NG20240310
                RAISERROR ('The order number provided is currently marked as Void. Please provide a non-void order number or select the Fill option to fill the order.', 14, 1); -- noqa: LT05

            UPDATE dbo.Order_No
            SET
                Void = 1
                , DateFilled = GETDATE()
                , Admin_Updated = GETDATE()
                , Admin_Name = 'Act_Top_Up_Void_CRM'
            WHERE Order_No = @OrderNo

            SELECT
                Onu.Order_No
                , Onu.Process
                , Onu.Filled
                , Onu.Paid
                , Onu.Void
                , Onu.DateFilled
                , o.Name
                , o.SKU
                , o.Price
                , o.DiscAmount
                , oNu.OrderTotal
                , 'This order has now been voided, please notify the Netsuite team so they can update NetSuite with the following Order Number:'
                + CAST(@OrderNo AS NVARCHAR(MAX))
                + '.' AS [Notify ERP]
            FROM dbo.Order_No AS Onu
            JOIN dbo.Orders AS o ON o.Order_No = Onu.Order_No
            WHERE
                Onu.Order_No = @OrderNo
                AND ISNULL(o.ParentItemID, 0) IN (0, 1)
        END;


END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
