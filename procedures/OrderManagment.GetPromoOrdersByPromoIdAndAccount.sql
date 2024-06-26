--liquibase formatted sql
--changeset moedaaboul:f1a3b7e8 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             :
--      Author : Moe Daaboul
--             :
--     Created : 2024-05-28
--             :
-- Description : Used to Get Promo Orders for Specific Account and Specific Promo Id and will get all Orders within the start date and End Date
---- =============================================
CREATE OR ALTER PROC [OrderManagment].[GetPromoOrdersByPromoIdAndAccount]
    (
        @promoId INT,
        @accountId INT
    )
AS
BEGIN
    DECLARE @promoStartDate DATETIME;
    DECLARE @promoEndDate DATETIME;

    CREATE TABLE #promoOrderTypes
    (
        orderTypeId INT NOT NULL
    );
    INSERT INTO #promoOrderTypes
    (
        orderTypeId
    )
    VALUES
    (59),
    (60),
    (70),
    (71);

    SELECT
        @promoStartDate = StartDate,
        @promoEndDate = EndDate
    FROM Products.tblPromotion
    WHERE PromotionId = @promoId;

    SELECT
        [on].Order_No,
        [on].Account_ID,
        [on].User_ID,
        [on].Customer_ID,
        [on].ShipTo,
        [on].Card_ID,
        [on].CreditTerms_ID,
        [on].DiscountClass_ID,
        [on].OrderType_ID,
        [on].DateOrdered,
        [on].OrderTotal,
        [on].Tax,
        [on].ShipType,
        [on].Shipping,
        [on].Comments,
        [on].AuthNumber,
        [on].InvoiceNum,
        [on].TransactNum,
        [on].Shipper,
        [on].Tracking,
        [on].Giftcard,
        [on].Delivery,
        [on].OrderDisc,
        [on].Credits,
        [on].AddonTotal,
        [on].Coup_Code,
        [on].Cert_Code,
        [on].Affiliate,
        [on].Referrer,
        [on].Process,
        [on].Filled,
        [on].DateFilled,
        [on].DateDue,
        [on].Paid,
        [on].CommissionPaid,
        [on].PayPalStatus,
        [on].Reason,
        [on].OfflinePayment,
        [on].Notes,
        [on].Admin_Updated,
        [on].Admin_Name,
        [on].AdminCredit,
        [on].AdminCreditText,
        [on].Printed,
        [on].Status,
        [on].Void,
        [on].User_IPAddress,
        [on].Parent_Paid,
        [on].Parent_InvoiceNum, [on].E911Tax
    FROM dbo.Orders AS o
    JOIN dbo.Order_No AS [on]
        ON o.Order_No = [on].Order_No
    WHERE
        [on].OrderType_ID IN
        (
            SELECT orderTypeId FROM #promoOrderTypes
        )
        AND [on].Account_ID = @accountId
        AND [on].DateOrdered >= @promoStartDate
        AND [on].DateOrdered < @promoEndDate
        AND o.Dropship_Qty = @promoId;

    DROP TABLE #promoOrderTypes;

END;
