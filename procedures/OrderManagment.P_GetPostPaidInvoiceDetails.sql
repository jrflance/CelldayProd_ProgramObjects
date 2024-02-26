--liquibase formatted sql
--changeset MoeDaaboul:795f1910 stripComments:false runOnChange:true splitStatements:false
/* =============================================
             :
      Author : Melissa Rios
             :
     Created : 2020-08-10
             :
 Description : Generates Detail Data for Post-paid invoices based on invoice number input
             :
  MR20200908 : Updated the naming of "Activation Spiff" to "Postpaid Instant Spiff"
  MR20211105 : Added the LEFT JOIN of Orders.tblOrderLinking to bring back the OrderNoLinkingID GUID
			 :	and added CASE statement to multiply the "Multiple Form of Payment" types by negative one.
  MR20211202 : Excluded Account Balance Product ID and Order type ID 80
  MR20220107 : Switched the order type description to say "Payment" or "Refund" for order types 77 & 78,
			 :	and switched the product name to be "Credit Card Purchase" or "Credit Card Refund".
  MR20220119 : Separated "Credit Card Refund" out from "Credit Card Purchase"
  MR20220121 : Added the "Replace" statment to remove "postpaid" from the order type description.
  MR20220602 : Added a left join to the products table and added product ID of zero to the case statments in
  order to bring back cases where that product ID got ACHd.
  SK20240223 : Added Activation Fee items
 ============================================= */

ALTER PROCEDURE [OrderManagment].[P_GetPostPaidInvoiceDetails]
    (@InvoiceNum VARCHAR(20))
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    --DECLARE @InvoiceNum VARCHAR(20) = '192153244'

    SELECT
        n.DateFilled AS [Date Filled (CST)],
        n.Order_No AS [Order Number],
        ol.OrderNoLinkingId,
        CASE
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 4
                THEN
                    'Postpaid Instant Spiff'
            WHEN
                n.OrderType_ID IN (77)
                AND d.Product_ID IN (0, 15693)
                THEN  --Purchase Credit Card products on prod and master
                    'Payment'						--MR20220107
            WHEN
                n.OrderType_ID IN (78)
                AND d.Product_ID IN (0, 15693)
                THEN  --Purchase Credit Card products on prod and master
                    'Refund'						--MR20220119
            ELSE
                REPLACE(oti.OrderType_Desc, 'Postpaid', '')
        END AS [Order Type],
        CASE
            WHEN
                n.OrderType_ID IN (77)
                AND d.Product_ID IN (0, 15693)
                THEN  --Purchase Credit Card products on prod and master
                    'Credit Card Purchase'						--MR20220107
            WHEN
                n.OrderType_ID IN (78)
                AND d.Product_ID IN (0, 15693)
                THEN  --Purchase Credit Card products on prod and master
                    'Credit Card Refund'						--MR20220119
            WHEN
                n.OrderType_ID IN (22)
                AND p.Product_Type = 17
                THEN -- Activation FEE
                    'Activation Fee' --SK20240223
            ELSE d.Name
        END AS [Product],
        CASE
            WHEN n.OrderType_ID IN (77, 78)	--Postpaid Multi Forms Of Payment & Postpaid Refund Multi Forms Of Payment
                THEN (SUM(d.Price) - SUM(d.DiscAmount) + SUM(ISNULL(d.Fee, 0))) * -1
            ELSE SUM(d.Price) - SUM(d.DiscAmount) + SUM(ISNULL(d.Fee, 0))
        END AS Charge
    FROM dbo.Order_No AS n
    JOIN dbo.Orders AS d
        ON n.Order_No = d.Order_No
    LEFT JOIN dbo.Products AS p
        ON p.Product_ID = d.Product_ID
    JOIN dbo.OrderType_ID AS oti
        ON oti.OrderType_ID = n.OrderType_ID
    LEFT JOIN Orders.tblOrderLinking AS ol
        ON ol.OrderNo = n.Order_No
    WHERE
        n.Status = @InvoiceNum
        AND n.Filled = 1
        AND n.Void = 0
        AND n.Process = 1
        AND d.Product_ID NOT IN (15692)				--MR20211202 Account Balance Prod
        AND n.OrderType_ID <> 80				--MR20211202
    GROUP BY CASE
        WHEN
            n.OrderType_ID = 22
            AND p.Product_Type = 4
            THEN
                'Postpaid Instant Spiff'
        WHEN
            n.OrderType_ID IN (77)
            AND d.Product_ID IN (0, 15693)
            THEN --Purchase Credit Card products on prod
                'Payment' --MR20220107
        WHEN
            n.OrderType_ID IN (78)
            AND d.Product_ID IN (0, 15693)
            THEN --Purchase Credit Card products on prod
                'Refund'  --MR20220119
        ELSE
            REPLACE(oti.OrderType_Desc, 'Postpaid', '')
    END,
    CASE
        WHEN
            n.OrderType_ID IN (77)
            AND d.Product_ID IN (0, 15693)
            THEN --Purchase Credit Card products on prod
                'Credit Card Purchase' --MR20220107
        WHEN
            n.OrderType_ID IN (78)
            AND d.Product_ID IN (0, 15693)
            THEN --Purchase Credit Card products on prod
                'Credit Card Refund'   --MR20220119
        WHEN
            n.OrderType_ID IN (22)
            AND p.Product_Type = 17
            THEN -- Activation FEE
                'Activation Fee' --SK20240223
        ELSE
            d.Name
    END,
    n.DateFilled,
    n.Order_No,
    ol.OrderNoLinkingId,
    n.OrderType_ID
END;
