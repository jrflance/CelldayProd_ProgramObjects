--liquibase formatted sql
--changeset  BrandonStahl:6132af35-1ce3-4761-a179-60e5e34bfbd2 stripComments:false runOnChange:true splitStatements:false
--=============================================
-- Author:		Brandon Stahl
-- Create date: 2023-07-21
-- Description:	Report is used for CSRs to Add or Update shipping label S3 bucket URL on Trade In orders.
--
--=============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_Upsert_Shipping_Lable_To_TradeIn_Order]
    (
        @SessionAccountID INT,
        @MerchantAccountId INT,
        @TradeInOrderNo INT,
        @ShippingLabelURL VARCHAR(100),
        @Action VARCHAR(6)
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        DECLARE
            @PrePTradeInOrderTypeId INT = 72,
            @PostPTradeInOrderTypeId INT = 73,
            @ShippingLabelAddonId INT = 375,
            @AddAction VARCHAR(6) = 'ADD',
            @UpdateAction VARCHAR(6) = 'UPDATE',
            @ShippingOrderItemAddonId INT,
            @TradeInOrderId INT;

        IF (ISNULL(@SessionAccountID, 0) <> 2)
            BEGIN
                SELECT
                    'This report is highly restricted! Please see your T-Cetra ' +
                    'representative if you need access.' AS [Error Message];
                RETURN;
            END;

        IF (@Action != @AddAction AND @Action != @UpdateAction)
            BEGIN
                SELECT @Action + ' is not a supported Action.';
                RETURN;
            END;

        SET
            @TradeInOrderId =
            (
                SELECT TOP (1) o.ID
                FROM dbo.Order_No AS n
                JOIN dbo.Orders AS o ON n.Order_No = o.Order_No
                WHERE
                    n.OrderType_ID IN (@PrePTradeInOrderTypeId, @PostPTradeInOrderTypeId)
                    AND n.Order_No = @TradeInOrderNo
                    AND n.Account_ID = @MerchantAccountId
            );

        IF (ISNULL(@TradeInOrderId, 0) = 0)
            BEGIN
                SELECT
                    'Trade In Order ' + CAST(@TradeInOrderNo AS VARCHAR(10)) + ' was not found for Account Id '
                    + CAST(@MerchantAccountId AS VARCHAR(10)) + '.';
                RETURN;
            END;

        SET
            @ShippingOrderItemAddonId =
            (
                SELECT TOP (1) oia.OrderItemAddonsID
                FROM dbo.tblOrderItemAddons AS oia
                WHERE
                    oia.OrderID = @TradeInOrderId
                    AND oia.AddonsID = @ShippingLabelAddonId
            );

        IF (@Action = @AddAction)
            BEGIN
                IF (ISNULL(@ShippingOrderItemAddonId, 0) = 0)
                    BEGIN
                        INSERT INTO dbo.tblOrderItemAddons VALUES (@TradeInOrderId, @ShippingLabelAddonId, @ShippingLabelURL);

                        SELECT 'Shipping label was CREATED for Trade In Order ' + CAST(@TradeInOrderNo AS VARCHAR(10)) + '.';
                        RETURN;
                    END
                ELSE
                    BEGIN
                        SELECT
                            'Shipping Label ' + oia.AddonsValue + ' already exists for Trade In Order ' + CAST(@TradeInOrderNo AS VARCHAR(10)) +
                            '. Select the UPDATE action if you would like to update.'
                        FROM dbo.tblOrderItemAddons AS oia
                        WHERE
                            oia.AddonsID = @ShippingLabelAddonId
                            AND oia.OrderID = @TradeInOrderId;
                        RETURN;
                    END
            END
        ELSE
            BEGIN
                IF (ISNULL(@ShippingOrderItemAddonId, 0) != 0)
                    BEGIN
                        UPDATE oia
                        SET oia.AddonsValue = @ShippingLabelURL
                        FROM dbo.tblOrderItemAddons AS oia
                        WHERE oia.OrderItemAddonsID = @ShippingOrderItemAddonId;

                        SELECT 'Shipping label was UPDATED for Trade In Order ' + CAST(@TradeInOrderNo AS VARCHAR(10)) + '.';
                        RETURN;
                    END
                ELSE
                    BEGIN
                        SELECT
                            'No shipping label exists for Trade In Order ' + CAST(@TradeInOrderNo AS VARCHAR(10)) +
                            '. Select the Add action if you would like to add one.';
                        RETURN;
                    END;
            END;

    END TRY
    BEGIN CATCH
        SELECT 'An error occured while executing, please contact IT Support.';
    END CATCH;
END;
